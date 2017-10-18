{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
module Nix.Eval where

import           Control.Applicative
import           Control.Arrow
import           Control.Monad hiding (mapM, sequence)
import           Control.Monad.Fix
import           Data.Fix
import           Data.Foldable (foldl')
import qualified Data.Map as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Traversable as T
import           Data.Typeable (Typeable)
import           GHC.Generics
import           Nix.Pretty (atomText)
import           Nix.StringOperations (runAntiquoted)
import           Nix.Atoms
import           Nix.Expr
import           Prelude hiding (mapM, sequence)

-- | An 'NValue' is the most reduced form of an 'NExpr' after evaluation
-- is completed.
data NValueF m r
    = NVConstant NAtom
    | NVStr Text
    | NVList [r]
    | NVSet (Map.Map Text r)
    | NVFunction (Params r) (NValue m -> m r)
    | NVLiteralPath FilePath
    deriving (Generic, Typeable, Functor)

instance Show f => Show (NValueF m f) where
    showsPrec = flip go where
      go (NVConstant atom) = showsCon1 "NVConstant" atom
      go (NVStr      text) = showsCon1 "NVStr"      text
      go (NVList     list) = showsCon1 "NVList"     list
      go (NVSet     attrs) = showsCon1 "NVSet"      attrs
      go (NVFunction r _)  = showsCon1 "NVFunction" r
      go (NVLiteralPath p) = showsCon1 "NVLiteralPath" p

      showsCon1 :: Show a => String -> a -> Int -> String -> String
      showsCon1 con a d = showParen (d > 10) $ showString (con ++ " ") . showsPrec 11 a

type NValue m = Fix (NValueF m)

valueText :: Functor m => NValue m -> Text
valueText = cata phi where
    phi (NVConstant a)    = atomText a
    phi (NVStr t)         = t
    phi (NVList _)        = error "Cannot coerce a list to a string"
    phi (NVSet _)         = error "Cannot coerce a set to a string"
    phi (NVFunction _ _)  = error "Cannot coerce a function to a string"
    phi (NVLiteralPath p) = Text.pack p

buildArgument :: Params (NValue m) -> NValue m -> NValue m
buildArgument paramSpec arg = either error (Fix . NVSet) $ bindsMap paramSpec
  where
    bindsMap pSpec = case pSpec of
      Param name -> return $ Map.singleton name arg
      ParamSet (FixedParamSet s) Nothing -> lookupParamSet s
      ParamSet (FixedParamSet s) (Just name) ->
        Map.insert name arg <$> lookupParamSet s
      ParamSet _ _ -> error "Can't yet handle variadic param sets"
      ParamAnnot p _ -> bindsMap p
    go env k def = maybe (Left err) return $ Map.lookup k env <|> def
      where err = "Could not find " ++ show k
    lookupParamSet s = case arg of
        Fix (NVSet env) -> Map.traverseWithKey (go env) s
        _               -> Left "Unexpected function environment"

evalExpr :: MonadFix m => NExpr -> NValue m -> m (NValue m)
evalExpr = cata phi
  where
    phi (NSym var) = \env -> case env of
      Fix (NVSet s) -> maybe err return $ Map.lookup var s
      _ -> error "invalid evaluation environment"
     where err = error ("Undefined variable: " ++ show var)
    phi (NConstant x) = const $ return $ Fix $ NVConstant x
    phi (NStr str) = fmap (Fix . NVStr) . flip evalString str
    phi (NLiteralPath p) = const $ return $ Fix $ NVLiteralPath p
    phi (NEnvPath _) = error "Path expressions are not yet supported"

    phi (NUnary op arg) = \env -> arg env >>= \case
      Fix (NVConstant c) -> pure $ Fix $ NVConstant $ case (op, c) of
        (NNeg, NInt  i) -> NInt  (-i)
        (NNot, NBool b) -> NBool (not b)
        _               -> error $ "unsupported argument type for unary operator " ++ show op
      _ -> error "argument to unary operator must evaluate to an atomic type"
    phi (NBinary op larg rarg) = \env -> do
      lval <- larg env
      rval <- rarg env
      case (lval, rval) of
       (Fix (NVConstant lc), Fix (NVConstant rc)) -> pure $ Fix $ NVConstant $ case (op, lc, rc) of
         (NEq,  l, r) -> NBool $ l == r
         (NNEq, l, r) -> NBool $ l /= r
         (NLt,  l, r) -> NBool $ l <  r
         (NLte, l, r) -> NBool $ l <= r
         (NGt,  l, r) -> NBool $ l >  r
         (NGte, l, r) -> NBool $ l >= r
         (NAnd,  NBool l, NBool r) -> NBool $ l && r
         (NOr,   NBool l, NBool r) -> NBool $ l || r
         (NImpl, NBool l, NBool r) -> NBool $ not l || r
         (NPlus,  NInt l, NInt r) -> NInt $ l + r
         (NMinus, NInt l, NInt r) -> NInt $ l - r
         (NMult,  NInt l, NInt r) -> NInt $ l * r
         (NDiv,   NInt l, NInt r) -> NInt $ l `div` r
         _ -> error $ "unsupported argument types for binary operator " ++ show op
       (Fix (NVStr ls), Fix (NVStr rs)) -> case op of
         NConcat -> pure $ Fix $ NVStr $ ls `mappend` rs
         _ -> error $ "unsupported argument types for binary operator " ++ show op
       (Fix (NVSet ls), Fix (NVSet rs)) -> case op of
         NUpdate -> pure $ Fix $ NVSet $ rs `Map.union` ls
         _ -> error $ "unsupported argument types for binary operator " ++ show op
       _ -> error $ "unsupported argument types for binary operator " ++ show op

    phi (NSelect aset attr alternative) = go where
      go env = do
        aset' <- aset env
        ks    <- evalSelector True env attr
        case extract aset' ks of
         Just v  -> pure v
         Nothing -> case alternative of
           Just v  -> v env
           Nothing -> error "could not look up attribute in value"
      extract (Fix (NVSet s)) (k:ks) = case Map.lookup k s of
                                        Just v  -> extract v ks
                                        Nothing -> Nothing
      extract               _  (_:_) = Nothing
      extract               v     [] = Just v

    phi (NHasAttr aset attr) = \env -> aset env >>= \case
      Fix (NVSet s) -> evalSelector True env attr >>= \case
        [keyName] -> pure $ Fix $ NVConstant $ NBool $ keyName `Map.member` s
        _ -> error "attribute name argument to hasAttr is not a single-part name"
      _ -> error "argument to hasAttr has wrong type"

    phi (NList l) = \env ->
        Fix . NVList <$> mapM ($ env) l

    phi (NSet binds) = \env -> Fix . NVSet <$> evalBinds True env binds

    phi (NRecSet binds) = \env -> case env of
      (Fix (NVSet env')) -> do
        rec
          mergedEnv <- pure $ Fix $ NVSet $ evaledBinds `Map.union` env'
          evaledBinds <- evalBinds True mergedEnv binds
        pure mergedEnv
      _ -> error "invalid evaluation environment"

    phi (NLet binds e) = \env -> case env of
      (Fix (NVSet env')) -> do
        rec
          mergedEnv   <- pure $ Fix $ NVSet $ evaledBinds `Map.union` env'
          evaledBinds <- evalBinds True mergedEnv binds
        e mergedEnv
      _ -> error "invalid evaluation environment"

    phi (NIf cond t f) = \env -> do
      (Fix cval) <- cond env
      case cval of
        NVConstant (NBool True) -> t env
        NVConstant (NBool False) -> f env
        _ -> error "condition must be a boolean"

    phi (NWith scope e) = \env -> case env of
      (Fix (NVSet env')) -> do
        s <- scope env
        case s of
          (Fix (NVSet scope')) -> e . Fix . NVSet $ Map.union scope' env'
          _ -> error "scope must be a set in with statement"
      _ -> error "invalid evaluation environment"

    phi (NAssert cond e) = \env -> do
      (Fix cond') <- cond env
      case cond' of
        (NVConstant (NBool True)) -> e env
        (NVConstant (NBool False)) -> error "assertion failed"
        _ -> error "assertion condition must be boolean"

    phi (NApp fun x) = \env -> do
        fun' <- fun env
        case fun' of
            Fix (NVFunction argset f) -> do
                arg <- x env
                let arg' = buildArgument argset arg
                f arg'
            _ -> error "Attempt to call non-function"

    phi (NAbs a b) = \env -> do
        -- jww (2014-06-28): arglists should not receive the current
        -- environment, but rather should recursively view their own arg
        -- set
        args <- traverse ($ env) a
        return $ Fix $ NVFunction args b

evalString :: Monad m
           => NValue m -> NString (NValue m -> m (NValue m)) -> m Text
evalString env nstr = do
  let fromParts parts = Text.concat <$>
        mapM (runAntiquoted return (fmap valueText . ($ env))) parts
  case nstr of
    Indented parts -> fromParts parts
    DoubleQuoted parts -> fromParts parts

evalBinds :: Monad m => Bool -> NValue m ->
             [Binding (NValue m -> m (NValue m))] ->
             m (Map.Map Text (NValue m))
evalBinds allowDynamic env xs = buildResult <$> sequence (concatMap go xs) where
  buildResult :: [([Text], NValue m)] -> Map.Map Text (NValue m)
  buildResult = foldl' insert Map.empty . map (first reverse) where
    insert _ ([], _) = error "invalid selector with no components"
    insert m (p:ps, v) = modifyPath ps (insertIfNotMember p v) where
      alreadyDefinedErr = error $ "attribute " ++ attr ++ " already defined"
      attr = show $ Text.intercalate "." $ reverse (p:ps)

      modifyPath [] f = f m
      modifyPath (x:parts) f = modifyPath parts $ \m' -> case Map.lookup x m' of
        Nothing                -> Map.singleton x $ g Map.empty
        Just (Fix (NVSet m'')) -> Map.insert x (g m'') m'
        Just _                 -> alreadyDefinedErr
       where g = Fix . NVSet . f

      insertIfNotMember k x m'
        | Map.notMember k m' = Map.insert k x m'
        | otherwise = alreadyDefinedErr

  -- TODO: Inherit
  go (NamedVar x y) = [liftM2 (,) (evalSelector allowDynamic env x) (y env)]
  go _ = [] -- HACK! But who cares right now

evalSelector :: Monad m => Bool -> NValue m -> NAttrPath (NValue m -> m (NValue m)) -> m [Text]
evalSelector dyn env = mapM evalKeyName where
  evalKeyName (StaticKey k) = return k
  evalKeyName (DynamicKey k)
    | dyn       = runAntiquoted (evalString env) (fmap valueText . ($ env)) k
    | otherwise = error "dynamic attribute not allowed in this context"
