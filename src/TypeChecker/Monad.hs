{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveDataTypeable #-}

module TypeChecker.Monad (
    TC()
  , runTC

    -- Unification
  , unify
  , applySubst
  , getSubst

    -- Variables
  , freshName
  , freshVar
  , freshVarFromTParam
  , FreeVars, emitFreeVar, collectVars
  , UnboundIdentifier(..)
  , unboundIdentifier
  , withVarIndex
  , bindVars
  , withSkolems, skolems

    -- Types
  , freshInst, freshInst', withRigidInst
  ) where

import Dang.Monad
import QualName (QualName,Name,simpleName)
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
  { roBoundVars :: Set.Set Name
  , roSkolems   :: Skolems
  }

emptyRO :: RO
emptyRO  = RO
  { roBoundVars = Set.empty
  , roSkolems   = Set.empty
  }

bindVars :: [Name] -> TC a -> TC a
bindVars vs m = TC $ do
  ro <- ask
  local (ro { roBoundVars = roBoundVars ro `mappend` Set.fromList vs }) (unTC m)

withSkolems :: Skolems -> TC a -> TC a
withSkolems sv m = TC $ do
  ro <- ask
  local (ro { roSkolems = roSkolems ro `mappend` sv }) (unTC m)

skolems :: TC Skolems
skolems  = roSkolems `fmap` TC ask


-- Write-only Output -----------------------------------------------------------

type FreeVars = Set.Set (Name,Type)

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

emitFreeVar :: Name -> Type -> TC ()
emitFreeVar v ty = TC (put mempty { woVars = Set.singleton (v,ty) })


-- Read/Write State ------------------------------------------------------------

data RW = RW
  { rwSubst   :: Subst
  , rwIndex   :: !Index
  }

emptyRW :: RW
emptyRW  = RW
  { rwSubst   = emptySubst
  , rwIndex   = 0
  }


-- Primitive Operations --------------------------------------------------------

-- | Unify two types, modifying the internal substitution.
unify :: Type -> Type -> TC ()
unify l r = do
  ro <- TC ask
  rw <- TC get
  let u = rwSubst rw
  extSubst =<< mgu (roSkolems ro) (apply u l) (apply u r)

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

-- | Generate a fresh name, given a prefix and a set of taken names to avoid.
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
  return (uvar (TParam ix False ('t':show ix) k))

freshTParam :: TParam -> TC TParam
freshTParam p = do
  ix <- nextIndex
  return (p { paramIndex = ix })

-- | Generate a new type variable, given a @TParam@ as a template.
freshVarFromTParam :: TParam -> TC Type
freshVarFromTParam p = uvar `fmap` freshTParam p

-- | Freshly instantiate a @Scheme@.
freshInst :: Types a => Forall a -> TC a
freshInst qa = snd `fmap` freshInst' qa

-- | Freshly instantiate a @Scheme@, returning the newly bound parameters.
freshInst' :: Types a => Forall a -> TC ([TParam],a)
freshInst' (Forall ps a) = do
  ps' <- mapM freshTParam ps
  a'  <- applySubst (inst (map uvar ps') a)
  return (ps',a')

withRigidInst :: Types a => Forall a -> (Skolems -> a -> TC b) -> TC b
withRigidInst tc k = do
  (ps,ty) <- freshInst' tc
  let sv = Set.fromList ps
  withSkolems sv (k sv ty)

data UnboundIdentifier = UnboundIdentifier QualName
    deriving (Show,Typeable)

instance Exception UnboundIdentifier

-- | Generate an @UnboundIdentifier@ exception.
unboundIdentifier :: QualName -> TC a
unboundIdentifier  = raiseE . UnboundIdentifier
