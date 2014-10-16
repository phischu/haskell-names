-- This module uses the open recursion interface
-- ("Language.Haskell.Names.Open") to annotate the AST with binding
-- information.
{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, ImplicitParams,
    UndecidableInstances, OverlappingInstances, ScopedTypeVariables,
    TypeOperators, GADTs #-}
module Language.Haskell.Names.Annotated
  ( Scoped(..)
  , NameInfo(..)
  , annotate
  ) where

import Language.Haskell.Names.Types
import Language.Haskell.Names.RecordWildcards
import Language.Haskell.Names.Open.Base
import Language.Haskell.Names.Open.Instances ()
import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import qualified Language.Haskell.Names.LocalSymbolTable as Local
import Language.Haskell.Names.SyntaxUtils (nameToQName)
import Language.Haskell.Exts.Annotated
import Data.Proxy
import Data.Lens.Light
import Data.Typeable (Typeable)
  -- in GHC 7.8 Data.Typeable exports (:~:). Be careful to avoid the clash.
import Control.Applicative

-- This should be incorporated into Data.Typeable soon
import Type.Eq

annotate
  :: forall a l .
     (Resolvable (a (Scoped l)), Functor a, Typeable l)
  => Scope -> a l -> a (Scoped l)
annotate sc = annotateRec (Proxy :: Proxy l) sc . fmap (Scoped None)

annotateRec
  :: forall a l .
     (Typeable l, Resolvable a)
  => Proxy l -> Scope -> a -> a
annotateRec _ sc a = go sc a where
  go :: forall a . Resolvable a => Scope -> a -> a
  go sc a
    | ReferenceV <- getL nameCtx sc
    , Just (Eq :: QName (Scoped l) :~: a) <- dynamicEq
      = lookupValue (fmap sLoc a) sc <$ a
    | ReferenceT <- getL nameCtx sc
    , Just (Eq :: QName (Scoped l) :~: a) <- dynamicEq
      = lookupType (fmap sLoc a) sc <$ a
    | ReferenceM <- getL nameCtx sc
    , Just (Eq :: Name (Scoped l) :~: a) <- dynamicEq
      = lookupMethod (fmap sLoc a) sc <$ a
    | BindingV <- getL nameCtx sc
    , Just (Eq :: Name (Scoped l) :~: a) <- dynamicEq
      = Scoped ValueBinder (sLoc . ann $ a) <$ a
    | BindingT <- getL nameCtx sc
    , Just (Eq :: Name (Scoped l) :~: a) <- dynamicEq
      = Scoped TypeBinder (sLoc . ann $ a) <$ a
    | Just (Eq :: FieldUpdate (Scoped l) :~: a) <- dynamicEq
      = case a of
          FieldPun l n -> FieldPun l (lookupValue (sLoc <$> n) sc <$ n)
          FieldWildcard l ->
            let
              namesUnres = sc ^. wcNames
              resolve n =
                let Scoped info _ = lookupValue (sLoc l <$ UnQual () n) sc
                in info
              namesRes =
                map
                  (\f -> (wcFieldOrigName f, resolve $ wcFieldName f))
                  namesUnres
            in FieldWildcard $ Scoped (RecExpWildcard namesRes) (sLoc l)
          _ -> rmap go sc a
    | Just (Eq :: PatField (Scoped l) :~: a) <- dynamicEq
    , PFieldWildcard l <- a
      = PFieldWildcard $
          Scoped
            (RecPatWildcard $ map wcFieldOrigName $ sc ^. wcNames)
            (sLoc l)
    | otherwise
      = rmap go sc a

lookupValue :: QName l -> Scope -> Scoped l
lookupValue qn sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Local.lookupValue qn $ getL lTable sc of
        Right r -> LocalValue r
        _ ->
          case Global.lookupValue qn $ getL gTable sc of
            Global.Result r -> GlobalValue r
            Global.Error e -> ScopeError e
            Global.Special -> None

lookupType :: QName l -> Scope -> Scoped l
lookupType qn sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Global.lookupType qn $ getL gTable sc of
        Global.Result r -> GlobalType r
        Global.Error e -> ScopeError e
        Global.Special -> None

lookupMethod :: Name l -> Scope -> Scoped l
lookupMethod name sc = Scoped nameInfo (ann name)
  where
    qn = nameToQName name
    nameInfo =
      case Local.lookupValue qn $ getL lTable sc of
        Right r -> LocalValue r
        _ ->
          case Global.lookupMethod qn $ getL gTable sc of
            Global.Result r -> GlobalValue r
            Global.Error e -> ScopeError e
            Global.Special -> None
