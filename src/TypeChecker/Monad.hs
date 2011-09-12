{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}

module TypeChecker.Monad (
    TC()
  , runTC

    -- Unification
  , unify
  , applySubst

    -- Variables
  , freshName
  , freshVar
  , freshVarFromTParam
  , emitFreeVar
  , collectVars
  , UnboundIdentifier(..)
  , unboundIdentifier
  , withVarIndex
  , bindVars

    -- Types
  , freshInst
  ) where

import Dang.Monad
import QualName
import Syntax.AST (Var)
import TypeChecker.Types
import TypeChecker.Unify

import Control.Applicative (Applicative)
import Control.Monad.Fix (MonadFix)
import Data.Monoid (Monoid(..))
import Data.Typeable (Typeable)
import MonadLib
import qualified Data.Set as Set


newtype TC a = TC { unTC :: ReaderT RO (WriterT WO (StateT RW Dang)) a }
    deriving (Functor,Applicative,Monad,MonadFix)

runTC :: TC a -> Dang a
runTC (TC m) = fmap (fst . fst)
             $ runStateT emptyRW
             $ runWriterT
             $ runReaderT emptyRO m

instance BaseM TC Dang where
  inBase = TC . inBase

instance ExceptionM TC SomeException where
  raise = TC . raise

instance RunExceptionM TC SomeException where
  try = TC . try . unTC


-- Read-only Environment -------------------------------------------------------

data RO = RO
  { roBoundVars :: Set.Set Var
  }

emptyRO :: RO
emptyRO  = RO
  { roBoundVars    = Set.empty
  }

bindVars :: [Var] -> TC a -> TC a
bindVars vs m = TC $ do
  ro <- ask
  local (ro { roBoundVars = roBoundVars ro `mappend` Set.fromList vs }) (unTC m)


-- Write-only Output -----------------------------------------------------------

type FreeVars = Set.Set Var

data WO = WO
  { woVars :: FreeVars
  }

instance Monoid WO where
  mempty = WO
    { woVars = mempty
    }

  mappend wa wb = WO
    { woVars = woVars wa `mappend` woVars wb
    }

collectVars :: TC a -> TC (a,FreeVars)
collectVars (TC m) = TC $ do
  (a,wo) <- collect m
  return (a,woVars wo)

emitFreeVar :: Var -> TC ()
emitFreeVar v = TC (put mempty { woVars = Set.singleton v })


-- Read/Write State ------------------------------------------------------------

data RW = RW
  { rwSubst :: Subst
  , rwIndex :: !Index
  }

emptyRW :: RW
emptyRW  = RW
  { rwSubst = emptySubst
  , rwIndex = 0
  }


-- Primitive Operations --------------------------------------------------------

-- | Unify two types, modifying the internal substitution.
unify :: Type -> Type -> TC ()
unify l r = do
  u <- getSubst
  extSubst =<< mgu (apply u l) (apply u r)

-- | Get the current substitution.
getSubst :: TC Subst
getSubst  = rwSubst `fmap` TC get

-- | Extend the current substitution by merging in the given one.
extSubst :: Subst -> TC ()
extSubst u = do
  rw <- TC get
  TC (set rw { rwSubst = u @@ rwSubst rw })

-- | Apply the substitution to a type.
applySubst :: Types t => t -> TC t
applySubst ty = do
  rw <- TC get
  return (apply (rwSubst rw) ty)

-- | Reset the index base for a type-checking operation.
withVarIndex :: Index -> TC a -> TC a
withVarIndex i' m = do
  rw <- TC get
  TC (set rw { rwIndex = i' })
  a  <- m
  TC (set rw { rwIndex = rwIndex rw })
  return a

nextIndex :: TC Int
nextIndex  = do
  rw <- TC get
  TC (set rw { rwIndex = rwIndex rw + 1 })
  return (rwIndex rw)

freshName :: String -> Set.Set QualName -> TC String
freshName pfx fvs = loop
  where
  loop = do
    i <- nextIndex
    let name = pfx ++ show i
    if simpleName name `Set.member` fvs
       then loop
       else return name

-- | Generate fresh type variables, with the given kind.
freshVar :: Kind -> TC Type
freshVar k = do
  ix <- nextIndex
  return (TVar ix (TParam ('t':show ix) k))

freshVarFromTParam :: TParam -> TC Type
freshVarFromTParam p = do
  ix <- nextIndex
  return (TVar ix p)

data UnboundIdentifier = UnboundIdentifier QualName
    deriving (Show,Typeable)

instance Exception UnboundIdentifier

unboundIdentifier :: QualName -> TC a
unboundIdentifier  = raiseE . UnboundIdentifier

freshInst :: Forall Type -> TC Type
freshInst (Forall ps ty) = do
  vars <- mapM freshVarFromTParam ps
  applySubst =<< inst vars ty
