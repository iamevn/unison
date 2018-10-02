{-# LANGUAGE RecordWildCards, ScopedTypeVariables, ViewPatterns #-}

module Unison.Codebase.Branch where

--import Control.Monad (join)
--import Data.List.NonEmpty (nonEmpty)
import Data.Map (Map)
--import Data.Semigroup (sconcat)
--import Data.Foldable
import qualified Data.Map as Map
import Unison.Hashable (Hashable)
import qualified Unison.Hashable as H
import Unison.Codebase.Causal (Causal)
import qualified Unison.Codebase.Causal as Causal
import Unison.Codebase.Conflicted (Conflicted)
import qualified Unison.Codebase.Conflicted as Conflicted
import Unison.Codebase.Name (Name)
-- import Unison.Codebase.NameEdit (NameEdit)
import Unison.Codebase.TermEdit (TermEdit, Typing)
import qualified Unison.Codebase.TermEdit as TermEdit
import Unison.Codebase.TypeEdit (TypeEdit)
import Unison.Reference (Reference)

-- todo:
-- probably should refactor Reference to include info about whether it
-- is a term reference, a type decl reference, or an effect decl reference
-- (maybe combine last two)
--
-- While we're at it, should add a `Cycle Int [Reference]` for referring to
-- an element of a cycle of references.
--
-- If we do that, can implement various operations safely since we'll know
-- if we are referring to a term or a type (and can prevent adding a type
-- reference to the term namespace, say)

data Branch0 =
  Branch0 { termNamespace  :: Map Name (Conflicted Reference)
          , typeNamespace  :: Map Name (Conflicted Reference)
          , edited         :: Map Reference (Conflicted TermEdit)
          , editedDatas    :: Map Reference (Conflicted TypeEdit)
          , editedEffects  :: Map Reference (Conflicted TypeEdit) }

-- note: this doesn't necessarily update `termNamespace`
replaceTerm :: Reference -> Reference -> Typing -> Branch -> Branch
replaceTerm old new typ (Branch b) = Branch $ Causal.step go b where
  edit = Conflicted.one (TermEdit.Replace new typ)
  replace cs = Conflicted.map (\r -> if r == old then new else r) cs
  go b = b { edited = Map.insertWith (<>) old edit (edited b)
           , termNamespace = replace <$> termNamespace b }

deprecateTerm :: Reference -> Branch -> Branch
deprecateTerm old (Branch b) = Branch $ Causal.step go b where
  edit = Conflicted.one TermEdit.Deprecate
  delete c = Conflicted.delete old c
  go b = b { edited = Map.insertWith (<>) old edit (edited b)
           , termNamespace = Map.fromList
             [ (k, v) | (k, v0) <- Map.toList (termNamespace b),
                        Just v <- [delete v0] ] }

instance Semigroup Branch0 where
  Branch0 n1 nt1 t1 d1 e1 <> Branch0 n2 nt2 t2 d2 e2 = Branch0
    (Map.unionWith (<>) n1 n2)
    (Map.unionWith (<>) nt1 nt2)
    (Map.unionWith (<>) t1 t2)
    (Map.unionWith (<>) d1 d2)
    (Map.unionWith (<>) e1 e2)

merge :: Branch -> Branch -> Branch
merge (Branch b) (Branch b2) = Branch (Causal.merge b b2)

instance Hashable Branch0 where
  tokens (Branch0 {..}) =
    H.tokens termNamespace ++ H.tokens typeNamespace ++
    H.tokens edited ++ H.tokens editedDatas ++ H.tokens editedEffects

newtype Branch = Branch (Causal Branch0)

resolveTerm :: Name -> Branch -> Maybe (Conflicted Reference)
resolveTerm n (Branch (Causal.head -> b)) =
  Map.lookup n (termNamespace b)

resolveTermUniquely :: Name -> Branch -> Maybe Reference
resolveTermUniquely n b = resolveTerm n b >>= Conflicted.asOne


-- probably not super common
--addName :: Reference -> Name -> Branch -> Branch
--addName r new b = Branch $ Causal.step go b where
--  ro = Conflicted.one r
--  go b = b { termNamespace = Map.insert n ro (termNamespace b) }

addTerm :: Name -> Reference -> Branch -> Branch
addTerm n r (Branch b) = Branch $ Causal.step go b where
  ro = Conflicted.one r
  go b = b { termNamespace = Map.insert n ro (termNamespace b) }

addType :: Name -> Reference -> Branch -> Branch
addType n r (Branch b) = Branch $ Causal.step go b where
  ro = Conflicted.one r
  go b = b { termNamespace = Map.insert n ro (typeNamespace b) }

renameType :: Name -> Name -> Branch -> Branch
renameType old new (Branch b) =
  let
    bh = Causal.head b
    m0 = typeNamespace bh
  in Branch $ case Map.lookup old m0 of
    Nothing -> b
    Just rs ->
      let m1 = Map.insertWith (<>) new rs . Map.delete old $ m0
      in Causal.cons (bh { typeNamespace = m1 }) b

renameTerm :: Name -> Name -> Branch -> Branch
renameTerm old new (Branch b) =
  let
    bh = Causal.head b
    m0 = termNamespace bh
  in Branch $ case Map.lookup old m0 of
    Nothing -> b
    Just rs ->
      let m1 = Map.insertWith (<>) new rs . Map.delete old $ m0
      in Causal.cons (bh { termNamespace = m1 }) b

--
-- What does this actually do.
--sequence :: Branch v a -> Branch v a -> Branch v a
--sequence (Branch n1 t1 d1 e1) (Branch n2 t2 d2 e2) =
--  Branch (Map.unionWith Causal.sequence n1 n2)
--          (chain ) _

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo1 is replaced with foo3
-- what do we want the output to be?
--    foo  -> Conflicted (foo3, foo2)
--    foo1 -> foo3

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo1 is replaced with foo2
-- what do we want the output to be?
--    foo  -> foo2
--    foo1 -> foo2

-- example:
-- in b1: foo is replaced with Conflicted (foo1, foo2)
-- in b2: foo is replaced with foo2
-- what do we want the output to be?
--    foo -> foo2

-- v = Causal (Conflicted blah)
-- k = Reference

--bindMaybeCausal ::forall a. (Hashable a, Ord a) => Causal (Conflicted a) -> (a -> Maybe (Causal (Conflicted a))) -> Causal (Conflicted a)
--bindMaybeCausal cca f = case Causal.head cca of
--  Conflicted.One a -> case f a of
--    Just cca' -> Causal.sequence cca cca'
--    Nothing -> cca
--  Conflicted.Many as ->
--    Causal.sequence cca $ case nonEmpty . join $ (toList . f <$> toList as) of
--      -- Would be nice if there were a good NonEmpty.Set, but Data.NonEmpty.Set from `non-empty` doesn't seem to be it.
--      Nothing -> error "impossible, `as` was Many"
--      Just z -> sconcat z
--
--chain :: forall v k. Ord k => (v -> Maybe k) -> Map k (Causal (Conflicted v)) -> Map k (Causal (Conflicted v)) -> Map k (Causal (Conflicted v))
--chain toK m1 m2 =
--    let
--      chain' :: forall v k . (v -> Maybe k) -> (k -> Maybe (Causal (Conflicted v))) -> (k -> Maybe (Causal (Conflicted v))) -> (k -> Maybe (Causal (Conflicted v)))
--      chain' toK m1 m2 k = case m1 k of
--        Just ccv1 -> Just $ bindMaybeCausal ccv1 (\k -> m2 k >>= toK)
--        Nothing -> m2 k
--    in
--      Map.fromList
--        [ (k, v) | k <- Map.keys m1 ++ Map.keys m2
--                 , Just v <- [chain' toK (`Map.lookup` m1) (`Map.lookup` m2) k] ]

