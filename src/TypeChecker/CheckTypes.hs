{-# LANGUAGE DeriveDataTypeable #-}

module TypeChecker.CheckTypes where

import Dang.IO
import Dang.Monad
import Interface (IsInterface,funSymbols,funType)
import Pretty
import QualName
import TypeChecker.AST
import TypeChecker.Env
import TypeChecker.Monad
import TypeChecker.Types (Type(..),tarrow,kstar,Scheme,toScheme,Forall(..))
import TypeChecker.Unify (quantifyAll,typeVars)
import Variables (freeVars)
import qualified Syntax.AST as Syn

import Control.Monad (mapAndUnzipM,foldM,unless)
import Data.Maybe (fromMaybe)
import Data.Typeable (Typeable)
import qualified Data.Set as Set


type TypeAssumps = Assumps Scheme

-- | Turn an interface into an initial set of assumptions.
interfaceAssumps :: IsInterface iset => iset -> TypeAssumps
interfaceAssumps  = foldl step emptyAssumps . funSymbols
  where
  step env (qn,sym) = addAssump qn (Assump Nothing (funType sym)) env

-- | Lookup a type assumption in the environment.
typeAssump :: QualName -> TypeAssumps -> TC (Assump Type)
typeAssump qn env = case lookupAssump qn env of
  Just a  -> do
    ty <- applySubst =<< freshInst (aData a)
    return a { aData = ty }
  Nothing -> unboundIdentifier qn


-- Type Checking ---------------------------------------------------------------

-- | Add a series of primitive bindings to an environment.
addPrimBinds :: TypeAssumps -> [Syn.PrimTerm] -> TC TypeAssumps
addPrimBinds  = foldM addPrimBind

-- | Add a primitive term binding to the environment.
addPrimBind :: TypeAssumps -> Syn.PrimTerm -> TC TypeAssumps
addPrimBind env ptd = do
  let n = primName (Syn.primTermName ptd)
      a = Assump Nothing (Syn.primTermType ptd)

  logInfo $ concat
    [ "  Assuming: ", Syn.primTermName ptd
    , " :: ", pretty (Syn.primTermType ptd) ]

  return (addAssump n a env)

-- | Type-check a module.
tcModule :: IsInterface iset => iset -> Syn.Module -> TC [Decl]
tcModule iset m = do
  logInfo ("Checking module: " ++ pretty (Syn.modName m))
  let ns = Syn.modNamespace m
  env <- addPrimBinds (interfaceAssumps iset) (Syn.modPrimTerms m)
  mapM (tcTopTypedDecl ns env) (Syn.modTyped m)

-- | Type-check a top-level, typed declaration.
tcTopTypedDecl :: Namespace -> TypeAssumps -> Syn.TypedDecl -> TC Decl
tcTopTypedDecl ns env td = do
  ((ty,m),fvs) <- collectVars (tcMatch env (Syn.typedBody td))

  -- this should be caught by the module system, but if not, catch it here.
  unless (Set.null fvs) (unexpectedFreeVars fvs)

  -- fix the inferred type, given information from the signature
  oty <- freshInst (Syn.typedType td)
  unify oty ty
  ty' <- applySubst ty

  -- generate the type-variables needed for this declaration
  let tvars = map snd (Set.toList (typeVars ty'))
      name  = qualName ns (Syn.typedName td)
      decl  = Decl
        { declName = name
        , declBody = Forall tvars m
        }

  -- dump some information about the checked declaration
  logInfo (pretty name ++ " :: " ++ pretty (quantifyAll ty'))
  logInfo (pretty decl)
  return decl

-- | Type-check a variable introduction.
tcMatch :: TypeAssumps -> Syn.Match -> TC (Type,Match)
tcMatch env m = case m of

  Syn.MTerm t -> do
    (ty,t') <- tcTerm env t
    ty'     <- applySubst ty
    return (ty',MTerm t' ty')

  Syn.MPat p m' -> tcPat env p $ \ env' pty p' -> do
    (ty,m'') <- tcMatch env' m'
    pty'     <- applySubst pty
    p''      <- applySubst p'
    return (pty' `tarrow` ty, MPat p'' m'')

-- | Type-check a pattern.
tcPat :: TypeAssumps -> Syn.Pat -> (TypeAssumps -> Type -> Pat -> TC a) -> TC a
tcPat env p k = case p of

  Syn.PWildcard -> do
    v <- freshVar kstar
    k env v (PWildcard v)

  Syn.PVar n -> do
    v <- freshVar kstar
    k (addAssump (simpleName n) (Assump Nothing (toScheme v)) env) v (PVar n v)

-- | Type-check terms in the syntax into system-f like terms.
tcTerm :: TypeAssumps -> Syn.Term -> TC (Type,Term)
tcTerm env tm = case tm of

  Syn.App f xs -> do
    (xtys,xs') <- mapAndUnzipM (tcTerm env) xs

    (fty,f') <- tcTerm env f
    res      <- freshVar kstar
    let inferred = foldr tarrow res xtys
    unify fty inferred
    return (res, App f' [] xs')

  Syn.Let ts us e -> tcLet env ts us e

  Syn.Abs m -> tcAbs env m

  Syn.Local n -> do
    a  <- typeAssump (simpleName n) env
    return (aData a, fromMaybe (Local n) (aBody a))

  Syn.Global qn -> do
    a  <- typeAssump qn env
    return (aData a, fromMaybe (Global qn) (aBody a))

  Syn.Prim{} -> fail "prim"

  Syn.Lit l -> do
    (ty,l') <- tcLit l
    return (ty,Lit l')

-- | Type-check a let expression.
tcLet :: TypeAssumps -> [Syn.TypedDecl] -> [Syn.UntypedDecl] -> Syn.Term
      -> TC (Type,Term)
tcLet env ts us e = do
  env0       <- addNameVars env (map Syn.typedName ts ++ map Syn.untypedName us)
  (env1,ts') <- tcTypedDecls env0 ts
  us'        <- tcUntypedDecls env0 us
  (ty,e')    <- tcTerm env0 e
  return (ty, Let (reverse ts' ++ us') e')

-- | Introduce fresh type variables for all names in a block of bindings.
addNameVars :: TypeAssumps -> [Name] -> TC TypeAssumps
addNameVars = foldM $ \ env n -> do
  v <- freshVar kstar
  return (addAssump (simpleName n) (Assump Nothing (toScheme v)) env)

tcTypedDecls :: TypeAssumps -> [Syn.TypedDecl] -> TC (TypeAssumps,[Decl])
tcTypedDecls env0 = foldM step (env0,[])
  where
  step (env,tds) td = do
    (env',td') <- tcTypedDecl env td
    return (env',td':tds)

-- | Type-check a typed declaration that shows up in a let-expression.
tcTypedDecl :: TypeAssumps -> Syn.TypedDecl -> TC (TypeAssumps,Decl)
tcTypedDecl env td = do
  ((ty,m),fvs) <- collectVars (tcMatch env (Syn.typedBody td))
  let vars = map snd (Set.toList (typeVars ty))
      name = simpleName (Syn.typedName td)
      decl = Decl
        { declName = name
        , declBody = Forall vars m
        }

      env' = addAssump name (Assump Nothing (quantifyAll ty)) env

  return (env, decl)

-- | Type-check a block of untyped declarations that show up in a
-- let-expression.
tcUntypedDecls :: TypeAssumps -> [Syn.UntypedDecl] -> TC [Decl]
tcUntypedDecls _env _us = do
  logError "tcUntypedDecls not implemented"
  return []

-- | Translate an abstraction, into a let expression with a fresh name.
tcAbs :: TypeAssumps -> Syn.Match -> TC (Type,Term)
tcAbs env m = do
  (ty,m') <- tcMatch env m
  lam     <- freshName "_lam" (freeVars m')
  let decl = Decl (simpleName lam) (Forall [] m')
  return (ty, Let [decl] (Local lam))

-- | Type-check a literal.
tcLit :: Syn.Literal -> TC (Type,Syn.Literal)
tcLit l = case l of
  Syn.LInt{} -> return (TCon (primName "Int"), l)


-- Errors ----------------------------------------------------------------------

data TypeCheckingError
  = UnexpectedFreeVars FreeVars
    deriving (Show,Typeable)

instance Exception TypeCheckingError

unexpectedFreeVars :: FreeVars -> TC a
unexpectedFreeVars  = raiseE . UnexpectedFreeVars
