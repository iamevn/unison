{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

module Unison.Codebase.Branch2 where

-- import qualified Unison.Codebase.Branch as Branch

import           Prelude                  hiding (head,subtract)

import           Control.Lens             hiding (children)
-- import           Control.Monad            (join)
-- import           Data.GUID                (genText)
import           Data.List                (intercalate)
import qualified Data.Map                 as Map
import           Data.Map                 (Map)
import           Data.Text                (Text)
import qualified Data.Text as Text

import qualified Unison.Codebase.Causal2  as Causal
import           Unison.Codebase.Causal2   (Causal)
import           Unison.Codebase.TermEdit (TermEdit)
import           Unison.Codebase.TypeEdit (TypeEdit)
import           Unison.Codebase.Path     (NameSegment, Path(Path))
import qualified Unison.Codebase.Path as Path
import           Unison.Hash              (Hash)
import           Unison.Hashable (Hashable)
import qualified Unison.Hashable as H
import           Unison.Reference         (Reference)
import           Unison.Referent          (Referent)
import qualified Unison.Util.Relation     as R
import           Unison.Util.Relation     (Relation)

data RepoRef
  = Local
  | Github { username :: Text, repo :: Text, commit :: Text }
  deriving (Eq, Ord, Show)

-- type EditGuid = Text

data RepoLink a = RepoLink RepoRef a
  deriving (Eq, Ord, Show)

-- type Link = RepoLink Hash
-- type EditLink = RepoLink EditGuid
--
-- data UnisonRepo = UnisonRepo
--   { _rootNamespace :: Link
--   , _editMap :: EditMap
--   , _editNames :: Relation Text EditGuid
--   } deriving (Eq, Ord, Show)
--
-- data Edits = Edits
--   { _termEdits :: Relation Reference TermEdit
--   , _typeEdits :: Relation Reference TypeEdit
--   } deriving (Eq, Ord, Show)

-- newtype EditMap =
--   EditMap { toMap :: Map EditGuid (Causal Edits) }
--   deriving (Eq, Ord, Show)
--
-- type FriendlyEditNames = Relation Text EditGuid

-- data Codebase' = Codebase'
--   { namespaceRoot :: Branch
--   , edits :: ???
--   }

newtype Branch m = Branch { _history :: Causal m (Branch0 m) }

head :: Branch m -> Branch0 m
head (Branch c) = Causal.head c

headHash :: Branch m -> Hash
headHash (Branch c) = Causal.currentHash c

data Branch0 m = Branch0
  { _terms :: Relation NameSegment Reference
  , _types :: Relation NameSegment Reference
  -- Q: How will we handle merges and conflicts for `children`?
  --    Should this be a relation?
  --    What is the UX to resolve conflicts?
  , _children :: Map NameSegment (Hash, m (Branch m))
  }
makeLenses ''Branch0
makeLenses ''Branch

data ForkFailure = SrcNotFound | DestExists

-- copy a path to another path
fork
  :: Monad m => Branch m -> Path -> Path -> m (Either ForkFailure (Branch m))
fork root src dest = do
  -- descend from root to src to get a Branch srcBranch
  getAt root src >>= \case
    Nothing -> pure $ Left SrcNotFound
    Just src' -> setIfNotExists root dest src' >>= \case
      Nothing -> pure $ Left DestExists
      Just root' -> pure $ Right root'

-- Move the node at src to dest.
-- It's okay if `dest` is inside `src`, just create empty levels.
-- Try not to `step` more than once at each node.
move
  :: Monad m => Branch m -> Path -> Path -> m (Either ForkFailure (Branch m))
move root src dest = do
  getAt root src >>= \case
    Nothing -> pure $ Left SrcNotFound
    Just src' ->
      -- make sure dest doesn't already exist
      getAt root dest >>= \case
        Just _destExists -> pure $ Left DestExists
        -- modify last shared ancestor of `src` and `dest`:
        -- if lsa = src then setAt empty dest src'
        -- else
        --    in src branch of lsa, delete src, removing newly empty parents.
        --      (is it ok to throw away this history?)
        --    in dest branch of lsa, add src at dest
        --    update lsa, simultaneously update src branch and dest branch
        Nothing -> error "todo"

setIfNotExists
  :: Monad m => Branch m -> Path -> Branch m -> m (Maybe (Branch m))
setIfNotExists root dest b =
  getAt root dest >>= \case
    Just _destExists -> pure Nothing
    Nothing -> Just <$> setAt root dest b

setAt :: Monad m => Branch m -> Path -> Branch m -> m (Branch m)
setAt root dest b = modifyAt root dest (const b)

getAt :: Monad m
      => Branch m
      -> Path
      -> m (Maybe (Branch m))
-- todo: return Nothing if exists but is empty
getAt root path = case Path.toList path of
  [] -> pure $ Just root
  seg : path -> case Map.lookup seg (_children $ head root) of
    Nothing -> pure Nothing
    Just (_h, m) -> do
      root <- m
      getAt root (Path path)

empty :: Branch m
empty = Branch $ Causal.one (Branch0 mempty mempty mempty)

-- Modify the branch0 at the head of at `path` with `f`,
-- after creating it if necessary.  Preserves history.
stepAt :: Monad m
       => Branch m
       -> Path
       -> (Branch0 m -> Branch0 m)
       -> m (Branch m)
stepAt b path f = stepAtM b path (pure . f)

-- Modify the branch0 at the head of at `path` with `f`,
-- after creating it if necessary.  Preserves history.
stepAtM :: Monad m
        => Branch m
        -> Path
        -> (Branch0 m -> m (Branch0 m))
        -> m (Branch m)
stepAtM (Branch c) path f = case Path.toList path of
  [] -> do
    let b0 = Causal.head c
    b0' <- f b0
    let c' = Causal.cons b0' c
    pure (Branch c')
  seg : path ->
    let recurse b@(Branch c) = do
          b' <- stepAtM b (Path path) f
          let c' = Causal.step
               (over children $ Map.insert seg (headHash b', pure b')) c
          pure (Branch c')
    in case Map.lookup seg (_children $ Causal.head c) of
      Nothing -> recurse empty
      Just (_h, m) -> m >>= recurse

-- Modify the Branch at `path` with `f`, after creating it if necessary.
-- Because it's a `Branch`, it overwrites the history at `path`.
modifyAt :: Monad m
  => Branch m -> Path -> (Branch m -> Branch m) -> m (Branch m)
modifyAt b path f = modifyAtM b path (pure . f)

-- Modify the Branch at `path` with `f`, after creating it if necessary.
-- Because it's a `Branch`, it overwrites the history at `path`.
modifyAtM :: Monad m
  => Branch m -> Path -> (Branch m -> m (Branch m)) -> m (Branch m)
modifyAtM b path f = case Path.toList path of
  [] -> f b
  seg : path ->
    let recurse b@(Branch c) = do
          b' <- modifyAtM b (Path path) f
          let c' = Causal.step
               (over children $ Map.insert seg (headHash b', pure b')) c
          pure (Branch c')
    in case Map.lookup seg (_children $ head b) of
        Nothing -> recurse empty
        Just (_h, m) -> m >>= recurse

instance Hashable (Branch0 m) where
  tokens b =
    [ H.accumulateToken . R.toList $ (_terms b)
    , H.accumulateToken . R.toList $ (_types b)
    , H.accumulateToken (fst <$> _children b)
    ]

-- getLocalBranch :: Hash -> IO Branch
-- getGithubBranch :: RemotePath -> IO Branch
-- getLocalEdit :: GUID -> IO Edits

-- makeLenses ''Namespace
-- makeLenses ''Edits
-- makeLenses ''Causal