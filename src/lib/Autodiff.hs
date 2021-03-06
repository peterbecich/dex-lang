-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Autodiff (linearize, transposeMap) where

import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.Writer
import Data.Foldable
import qualified Data.Map.Strict as M

import Type
import Env
import Syntax
import Cat
import PPrint
import Subst
import Embed
import Record

-- -- === linearization ===

type EmbedSubM a = ReaderT SubstEnv Embed a
newtype LinA a = LinA { runLinA :: EmbedSubM (a, EmbedSubM a) }

linearize :: TopEnv -> Scope -> LamExpr -> Atom
linearize env scope (LamExpr b _ expr) = fst $ flip runEmbed scope $ do
  buildLam noEffect NonLin b $ \x -> do
    (y, yt) <- runReaderT (runLinA (linearizeExpr env expr)) (b @> L x)
    -- TODO: check linearity
    fLin <- buildLam noEffect Lin b $ \xt -> runReaderT yt (b @> L xt)
    return $ makePair y fLin

linearizeExpr :: TopEnv -> Expr -> LinA Atom
linearizeExpr topEnv expr = case expr of
  Decl (Let b bound) body -> LinA $ do
    (env, tEnvM) <- runLinA $ liftA (\x -> b @> L x) $ linearizeCExpr topEnv bound
    (ans, fLin) <- extendR env $ runLinA $ linearizeExpr topEnv body
    return (ans, do tEnv <- tEnvM
                    extendR tEnv fLin)
  CExpr e -> linearizeCExpr topEnv e
  Atom x  -> linearizeAtom x

-- TODO: handle a binder (will it be linear? nonlinear? specified by a flag?)
linearizeLamExpr :: TopEnv -> [Var] -> LamExpr -> EmbedSubM LamExpr
linearizeLamExpr topEnv vs (LamExpr _ eff body) =
  buildLamExpr eff ("_":>unitTy) $ \_ -> do
    (body', bodyTan)  <- runLinA $ linearizeExpr topEnv body
    fLin <- buildLam eff Lin ("t":>envTy) $ \t -> do
      ~(Tup t') <- unpackRec t
      let env' = fmap L $ fold $ zipWith (@>) vs t'
      lift $ runReaderT bodyTan env'
    return $ makePair body' fLin
  where envTy = RecType $ Tup $ map varAnn vs

linearizeCExpr :: TopEnv -> CExpr -> LinA Atom
linearizeCExpr topEnv (App _ (Var v) arg) | v `isin` linRules topEnv = LinA $ do
  (x, t) <- runLinA $ linearizeAtom arg
  ~(Tup [y, f]) <- emit (App NonLin (linRules topEnv ! v) x) >>= unpackRec
  return (y, do t' <- t
                emit $ App Lin f t')
linearizeCExpr topEnv expr = case expr' of
  ScalarUnOp  FNeg x     ->     liftA  (ScalarUnOp  FNeg) x     `bindLin` emit
  ScalarBinOp FAdd x1 x2 ->     liftA2 (ScalarBinOp FAdd) x1 x2 `bindLin` emit
  ScalarBinOp FSub x1 x2 ->     liftA2 (ScalarBinOp FSub) x1 x2 `bindLin` emit
  ScalarBinOp FMul x1 x2 -> tensLiftA2 (ScalarBinOp FMul) x1 x2
  -- TODO: define this in the prelude instead (need richer deriv rules)
  ScalarBinOp FDiv x y -> LinA $ do
    (x', tx) <- runLinA x
    (y', ty) <- runLinA y
    ans <- div' x' y'
    return (ans, do tx' <- tx
                    ty' <- ty
                    linearizedDiv x' y' tx' ty')
  RunReader l r lam@(LamExpr b eff _) -> LinA $ do
    (r', rt) <- runLinA r
    linVars <- asks getEnvVars
    lam' <- linearizeLamExpr topEnv linVars lam
    (ans, lin) <- fromPair =<< emit (RunReader l r' lam')
    return ( ans
           , do rt' <- rt
                arg <- asks $ tangentTuple linVars
                effLam' <- buildLamExpr eff b $ \_ -> emit $ App Lin lin arg
                emit $ RunReader l rt' effLam')
  RunWriter l lam@(LamExpr b eff _) -> LinA $ do
    linVars <- asks getEnvVars
    lam' <- linearizeLamExpr topEnv linVars lam
    (ansLin, w) <- fromPair =<< emit (RunWriter l lam')
    (ans, lin) <- fromPair ansLin
    return ( makePair ans w
           , do arg <- asks $ tangentTuple linVars
                effLam' <- buildLamExpr eff b $ \_ -> emit $ App Lin lin arg
                emit $ RunWriter l effLam')
  PrimEffect l ty  MAsk     -> pure  (PrimEffect l ty MAsk)      `bindLin` emit
  PrimEffect l ty (MTell x) -> liftA (PrimEffect l ty . MTell) x `bindLin` emit
  RecGet x i -> liftA (flip RecGet i) x `bindLin` emit
  _ -> error $ "not implemented: " ++ pprint expr
  where expr' = fmapExpr expr id linearizeAtom id

getEnvVars :: SubstEnv -> [Var]
getEnvVars env = [v:>getType x | (v, L x) <- envPairs env]

linearizedDiv :: Atom -> Atom -> Atom -> Atom -> EmbedSubM Atom
linearizedDiv x y tx ty = do
  tx'  <- div' tx y
  ty'  <- mul ty x
  ySq  <- mul y y
  ty'' <- div' ty' ySq >>= neg
  add tx' ty''

tangentTuple :: [Var] -> SubstEnv -> Atom
tangentTuple vs env = makeTup [fromL (env ! v) | v <- vs]

linearizePrimCon :: Con -> LinA Atom
linearizePrimCon con = case con' of
  Lit _    -> LinA $ return (x, zeroAt (getType x))  where x = Con con
  RecCon r -> liftA (Con . RecCon) $ sequenceA r
  _ -> error $ "not implemented: " ++ pprint con
  where con' = fmapExpr con id linearizeAtom id

linearizeAtom :: Atom -> LinA Atom
linearizeAtom atom = case atom of
  Var v -> LinA $ do
    maybeVal <- asks $ flip envLookup v
    case maybeVal of
      Just (L x) -> return (x, asks (fromL . (!v)))
      Nothing    -> return (atom, zeroAt (getType atom))
      _ -> error "unexpected lookup"
  Con con -> linearizePrimCon con
  _ -> error "Not implemented"

tensLiftA2 :: (a -> b -> CExpr) -> LinA a -> LinA b -> LinA Atom
tensLiftA2 f (LinA m1) (LinA m2) = LinA $ do
  (x1, mt1) <- m1
  (x2, mt2) <- m2
  ans <- emit $ f x1 x2
  return (ans, do t1 <- mt1
                  t2 <- mt2
                  tOut1 <- emit $ f x1 t2
                  tOut2 <- emit $ f t1 x2
                  add tOut1 tOut2)

bindLin :: LinA a -> (a -> EmbedSubM b) -> LinA b
bindLin (LinA m) f = LinA $ do
  (e, t) <- m
  x <- f e
  return (x, t >>= f)

instance Functor LinA where
  fmap = liftA

instance Applicative LinA where
  pure x = LinA $ return (x, return x)
  liftA2 f (LinA m1) (LinA m2) = LinA $ do
    (x1, t1) <- m1
    (x2, t2) <- m2
    return (f x1 x2, liftM2 f t1 t2)

-- -- === transposition ===

type LinVars = Env ()
type CotangentVals = MonMap Name [Atom]  -- TODO: consider folding as we go
type TransposeM a = WriterT CotangentVals (ReaderT (LinVars, SubstEnv) Embed) a

transposeMap :: Scope -> LamExpr -> Atom
transposeMap scope (LamExpr b _ expr) = fst $ flip runEmbed scope $ do
  buildLam noEffect Lin ("ct" :> getType expr) $ \ct -> do
    flip runReaderT mempty $ liftM fst $ runWriterT $
      withLinVar b $ transposeExpr expr ct

transposeExpr :: Expr -> Atom -> TransposeM ()
transposeExpr expr ct = case expr of
  Decl (Let b bound) body -> do
    let (eff, _) = getEffType bound
    linEff <- isLinEff eff
    lin <- isLin bound
    if lin || linEff
      then do
        ct' <- withLinVar b $ transposeExpr body ct
        transposeCExpr bound ct'
      else do
        x <- substTranspose bound >>= emitTo b
        extendR (asSnd (b @> L x)) $ transposeExpr body ct
  CExpr e -> transposeCExpr e ct
  Atom x  -> transposeAtom x ct

transposeCExpr :: CExpr -> Atom -> TransposeM ()
transposeCExpr expr ct = case expr of
  ScalarUnOp FNeg x -> do
    ctNeg <- neg ct
    transposeAtom x ctNeg
  ScalarBinOp FAdd x y -> do
    transposeAtom x ct
    transposeAtom y ct
  ScalarBinOp FSub x y -> do
    ctNeg <- neg ct
    transposeAtom x ct
    transposeAtom y ctNeg
  ScalarBinOp FMul x y -> do
    xLin <- isLin x
    if xLin
      then do
        y' <- substTranspose y
        ct' <- mul ct y'
        transposeAtom x ct'
      else do
        x' <- substTranspose x
        ct' <- mul ct x'
        transposeAtom y ct'
  ScalarBinOp FDiv x y -> do
    y' <- substTranspose y
    ct' <- div' ct y'
    transposeAtom x ct'
  RecGet x i -> do
    ~(Con (RecCon rZeros)) <- zeroAt (getType x)
    let ct' = Con $ RecCon $ recUpdate i ct rZeros
    transposeAtom x ct'
  -- TODO: de-dup RunReader/RunWriter a bit
  RunReader l r (LamExpr _ eff body) -> do
    let eff' = transposeEffect eff
    vs <- freeLinVars body
    body' <- buildLamExpr eff' ("_":>unitTy) $ \_ -> do
               vsCTs <- extractCTs vs $ transposeExpr body ct
               return $ Con $ RecCon $ Tup vsCTs
    (vsCTs, ctr) <- emit (RunWriter l body') >>= fromPair
    ~(Tup vsCTs') <- unpackRec vsCTs
    zipWithM_ (emitCT . varName) vs vsCTs'
    transposeAtom r ctr
  RunWriter l (LamExpr _ eff body) -> do
    (ctBody, ctEff) <- fromPair ct
    let eff' = transposeEffect eff
    vs <- freeLinVars body
    body' <- buildLamExpr eff' ("_":>unitTy) $ \_ -> do
               vsCTs <- extractCTs vs $ transposeExpr body ctBody
               return $ Con $ RecCon $ Tup vsCTs
    vsCTs <- emit (RunReader l ctEff body')
    ~(Tup vsCTs') <- unpackRec vsCTs
    zipWithM_ (emitCT . varName) vs vsCTs'
  PrimEffect l ty MAsk      -> void $ emit $ PrimEffect l ty (MTell ct)
  PrimEffect l ty (MTell x) -> do
    ct' <- emit $ PrimEffect l ty MAsk
    transposeAtom x ct'
  _ -> error $ "not implemented: transposition for: " ++ pprint expr

transposeCon :: Con -> Atom -> TransposeM ()
transposeCon con ct = case con of
  Lit _ -> return ()
  RecCon r -> do
    rCT <- unpackRec ct
    sequence_ $ recZipWith transposeAtom r rCT
  _ -> error $ "not implemented: transposition for: " ++ pprint con

transposeAtom :: Atom -> Atom -> TransposeM ()
transposeAtom atom ct = case atom of
  Var (v:>_) -> emitCT v ct
  Con con -> transposeCon con ct
  _ -> error $ "Can't transpose: " ++ pprint atom

transposeEffect :: Effect -> Effect
transposeEffect ~(Effect row tailVar) =
  Effect (fmap transposeOneEffect row) tailVar

transposeOneEffect :: OneEffect a -> OneEffect a
transposeOneEffect eff = case eff of
  Reader x -> Writer x
  Writer x -> Reader x
  State  x -> State  x

freeLinVars :: HasVars a => a -> TransposeM [Var]
freeLinVars x = do
  linVs <- asks fst
  return [v:>ty | (v, L ty) <- envPairs $ envIntersect linVs (freeVars x)]

isLin :: HasVars a => a -> TransposeM Bool
isLin x = liftM (not . null) $ freeLinVars x

-- TODO: allow nonlinear effects
isLinEff :: Effect -> TransposeM Bool
isLinEff ~(Effect row _) = return $ not $ null $ toList row

emitCT :: Name -> Atom -> TransposeM ()
emitCT v ct = tell $ MonMap $ M.singleton v [ct]

substTranspose :: Subst a => a -> TransposeM a
substTranspose x = do
  env <- asks snd
  scope <- looks fst
  return $ subst (env, scope) x

withLinVar :: Var -> TransposeM () -> TransposeM Atom
withLinVar v m = liftM snd $ extractCT v $ extendR (asFst (v@>())) m

extractCT :: Var -> TransposeM a -> TransposeM (a, Atom)
extractCT b m = do
  (ans, ctEnv) <- captureW m
  (ct, ctEnv') <- sepCotangent b ctEnv
  tell ctEnv'
  return (ans, ct)

extractCTs :: [Var] -> TransposeM () -> TransposeM [Atom]
extractCTs [] m = m >> return []
extractCTs (v:vs) m = do
  (vs', v') <- extractCT v $ extractCTs vs m
  return (v':vs')

sepCotangent :: MonadCat EmbedEnv m =>
                  Var -> CotangentVals -> m (Atom, CotangentVals)
sepCotangent (v:>ty) (MonMap m) = do
  ans <- sumAt ty $ M.findWithDefault [] v m
  return (ans, MonMap (M.delete v m))
