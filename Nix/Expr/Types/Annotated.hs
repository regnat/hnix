{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor      #-}
{-# LANGUAGE DeriveFoldable     #-}
{-# LANGUAGE DeriveTraversable  #-}
{-# LANGUAGE PatternSynonyms    #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE TemplateHaskell    #-}

-- | The source location annotated nix expression type and supporting types.
--
module Nix.Expr.Types.Annotated
  ( module Nix.Expr.Types.Annotated
  , Delta(..)
  )where

import           Control.Monad        hiding (forM_, mapM, sequence)
import           Data.Data
import           Data.Fix
import           Data.Function        (on)
import           Data.Functor.Compose
import           Data.Semigroup
import           GHC.Generics
import           Nix.Expr.Types
import           Nix.Parser.Library   (Delta(..))
import           Prelude              hiding (concat, concatMap, elem, foldr,
                                       mapM, minimum, readFile, sequence)
import           Text.Show.Deriving

-- | A location in a source file
data SrcSpan = SrcSpan{ spanBegin :: Delta
                      , spanEnd   :: Delta
                      }
  deriving (Ord, Eq, Generic, Typeable, Data, Show)

-- | A type constructor applied to a type along with an annotation
--
-- Intended to be used with 'Fix':
-- @type MyType = Fix (Compose (Ann Annotation) F)@
data Ann ann a = Ann{ annotation :: ann
                    , annotated  :: a
                    }
  deriving (Ord, Eq, Data, Generic, Typeable, Functor, Foldable, Traversable, Read, Show)

$(deriveShow1 ''Ann)

instance Semigroup SrcSpan where
  s1 <> s2 = SrcSpan ((min `on` spanBegin) s1 s2)
                     ((max `on` spanEnd) s1 s2)

type AnnF ann f = Compose (Ann ann) f

annToAnnF :: Ann ann (f (Fix (AnnF ann f))) -> Fix (AnnF ann f)
annToAnnF (Ann ann a) = AnnE ann a

type NExprLocF = AnnF SrcSpan NExprF

-- | A nix expression with source location at each subexpression.
type NExprLoc = Fix NExprLocF

pattern AnnE :: forall (t :: * -> *) t1.
                t1 -> t (Fix (Compose (Ann t1) t)) -> Fix (Compose (Ann t1) t)
pattern AnnE ann a = Fix (Compose (Ann ann a))

stripAnnotation :: Functor f => Fix (AnnF ann f) -> Fix f
stripAnnotation = ana (annotated . getCompose . unFix)

nApp :: NExprLoc -> NExprLoc -> NExprLoc
nApp e1@(AnnE s1 _) e2@(AnnE s2 _) = AnnE (s1 <> s2) (NApp e1 e2)
nApp _ _ = undefined

nUnary :: Ann SrcSpan NUnaryOp -> NExprLoc -> NExprLoc
nUnary (Ann s1 u) e1@(AnnE s2 _) = AnnE (s1 <> s2) (NUnary u e1)
nUnary _ _ = undefined

nBinary :: Ann SrcSpan NBinaryOp -> NExprLoc -> NExprLoc -> NExprLoc
nBinary (Ann s1 b) e1@(AnnE s2 _) e2@(AnnE s3 _) =
  AnnE (s1 <> s2 <> s3) (NBinary b e1 e2)
nBinary (Ann _ _) _ _ = undefined

nSelectLoc :: NExprLoc -> Ann SrcSpan (NAttrPath NExprLoc) -> Maybe NExprLoc -> NExprLoc
nSelectLoc e1@(AnnE s1 _) (Ann s2 ats) d = case d of
  Nothing               -> AnnE (s1 <> s2) (NSelect e1 ats Nothing)
  Just (e2@(AnnE s3 _)) -> AnnE (s1 <> s2 <> s3) (NSelect e1 ats (Just e2))
  Just _                -> undefined
nSelectLoc _ _ _ = undefined

nHasAttr :: NExprLoc -> Ann SrcSpan (NAttrPath NExprLoc) -> NExprLoc
nHasAttr e1@(AnnE s1 _) (Ann s2 ats) = AnnE (s1 <> s2) (NHasAttr e1 ats)
nHasAttr _ _ = undefined

nAbs :: Ann SrcSpan (Params NExprLoc) -> NExprLoc -> NExprLoc
nAbs (Ann s1 ps) e1@(AnnE s2 _) = AnnE (s1 <> s2) (NAbs ps e1)
nAbs (Ann _ _) _ = undefined

nStr :: Ann SrcSpan (NString NExprLoc) -> NExprLoc
nStr (Ann s1 s) = AnnE s1 (NStr s)
