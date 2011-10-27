{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}

module TypeChecker.Types where

import Pretty
import QualName
import Variables

import Control.Applicative ((<$>),(<*>))
import Control.Monad (guard)
import Data.Function (on)
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Serialize
    (get,put,Get,Putter,getWord8,putWord8,getWord32be,putWord32be,getListOf
    ,putListOf)
import qualified Data.Set as Set

type Index = Int

putIndex :: Putter Index
putIndex  = putWord32be . toEnum

getIndex :: Get Index
getIndex  = fromEnum <$> getWord32be

data Type
  = TApp Type Type
  | TInfix QualName Type Type
  | TCon QualName
  | TVar TParam
  | TGen TParam
    deriving (Eq,Show,Ord)

putType :: Putter Type
putType (TApp l r)     = putWord8 0 >> putType l     >> putType r
putType (TInfix n l r) = putWord8 1 >> putQualName n >> putType l >> putType r
putType (TCon n)       = putWord8 2 >> putQualName n
putType (TVar p)       = putWord8 3 >> putTParam p
putType (TGen p)       = putWord8 4 >> putTParam p

getType :: Get Type
getType  = getWord8 >>= \ tag ->
  case tag of
    0 -> TApp   <$> getType     <*> getType
    1 -> TInfix <$> getQualName <*> getType <*> getType
    2 -> TCon   <$> getQualName
    3 -> TVar   <$> getTParam
    4 -> TGen   <$> getTParam
    _ -> fail ("Invalid tag: " ++ show tag)

isTVar :: Type -> Bool
isTVar TVar{} = True
isTVar _      = False

instance Pretty Type where
  pp _ (TCon n)       = ppr n
  pp _ (TVar m)       = ppr m
  pp _ (TGen m)       = ppr m
  pp p (TApp a b)     = optParens (p > 1) (ppr a <+> pp 2 b)
  pp p (TInfix c a b) = optParens (p > 0) (pp 1 a <+> ppr c <+> pp 0 b)

instance FreeVars Type where
  freeVars (TCon qn)       = Set.singleton qn
  freeVars (TVar p)        = freeVars p
  freeVars (TGen _)        = Set.empty
  freeVars (TApp a b)      = freeVars a `Set.union` freeVars b
  freeVars (TInfix qn a b) = Set.singleton qn `Set.union` freeVars (a,b)

-- | Map a function over the generic variables in a type
mapGen :: (TParam -> TParam) -> Type -> Type
mapGen f (TApp a b)      = TApp (mapGen f a) (mapGen f b)
mapGen f (TInfix qn a b) = TInfix qn (mapGen f a) (mapGen f b)
mapGen f (TGen p)        = TGen (f p)
mapGen _ ty              = ty


data TParam = TParam
  { paramIndex      :: Index
  , paramFromSource :: Bool
  , paramName       :: String
  , paramKind       :: Kind
  } deriving (Show)

instance Eq TParam where
  (==) = (==) `on` paramIndex
  (/=) = (/=) `on` paramIndex

instance Ord TParam where
  compare = comparing paramIndex

instance FreeVars TParam where
  freeVars = Set.singleton . simpleName . paramName

instance Pretty TParam where
  pp _ p = text (paramName p)

setTParamIndex :: Index -> TParam -> TParam
setTParamIndex ix p = p { paramIndex = ix }

putTParam :: Putter TParam
putTParam p = putIndex (paramIndex p)
           >> put (paramFromSource p)
           >> put (paramName p)
           >> putKind (paramKind p)

getTParam :: Get TParam
getTParam  = TParam <$> getIndex <*> get <*> get <*> getKind

-- | Type-application introduction.
tapp :: Type -> Type -> Type
tapp  = TApp

-- | Arrow introduction.
tarrow :: Type -> Type -> Type
tarrow  = TInfix arrowConstr
infixr 9 `tarrow`

arrowConstr :: QualName
arrowConstr  = primName "->"

destInfix :: Type -> Maybe (QualName,Type,Type)
destInfix (TInfix qn l r) = return (qn,l,r)
destInfix _               = Nothing

destArrow :: Type -> Maybe (Type,Type)
destArrow ty = do
  (qn,l,r) <- destInfix ty
  guard (qn == arrowConstr)
  return (l,r)

destArgs :: Type -> [Type]
destArgs ty = fromMaybe [ty] $ do
  (l,r) <- destArrow ty
  return (l:destArgs r)

destTVar :: Type -> Maybe TParam
destTVar (TVar p) = return p
destTVar _        = Nothing

-- | Count the number of arguments to a function.
typeArity :: Type -> Int
typeArity ty = maybe 0 rec (destArrow ty)
  where
  rec (_,r) = 1 + typeArity r

type Kind = Type

putKind :: Putter Kind
putKind  = putType

getKind :: Get Kind
getKind  = getType

-- | The kind of types.
kstar :: Kind
kstar  = TCon (primName "*")

-- | The kind of type constructors.
karrow :: Kind -> Kind -> Kind
karrow  = TInfix arrowConstr
infixr 9 `karrow`

type Sort = Type

setSort :: Sort
setSort = TCon (primName "Set")

type Scheme = Forall Type

-- | Produce a type scheme that quantifies no variables.
toScheme :: Type -> Scheme
toScheme  = Forall []

-- | Things with quantified variables.
data Forall a = Forall [TParam] a
    deriving (Show,Eq,Ord)

putForall :: Putter a -> Putter (Forall a)
putForall p (Forall ps a) = putListOf putTParam ps >> p a

getForall :: Get a -> Get (Forall a)
getForall a = Forall <$> getListOf getTParam <*> a

forallParams :: Forall a -> [TParam]
forallParams (Forall ps _) = ps

forallData :: Forall a -> a
forallData (Forall _ a) = a

instance Pretty a => Pretty (Forall a) where
  pp _ (Forall ps a) = vars <+> pp 0 a
    where
    vars | null ps   = empty
         | otherwise = text "forall" <+> ppList 0 ps <> char '.'

instance FreeVars a => FreeVars (Forall a) where
  freeVars = freeVars  . forallData
