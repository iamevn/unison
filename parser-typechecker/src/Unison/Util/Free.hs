{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# Language ExistentialQuantification, Rank2Types #-}

module Unison.Util.Free where

import Control.Monad
import Control.Monad.Free (MonadFree (..))
import Control.Monad.Trans.Class
import Control.Monad.Trans.Cont
import Control.Monad.Trans.Except
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Reader
import qualified Control.Monad.Trans.State.Lazy as Lazy
import qualified Control.Monad.Trans.State.Strict as Strict

-- We would use another package for this if we knew of one.
-- Neither http://hackage.haskell.org/package/free
--     nor http://hackage.haskell.org/package/free-functors
--     nor http://hackage.haskell.org/package/freer
--     appear to have this.

data Free f a = Pure a | forall x . Bind (f x) (x -> Free f a)

eval :: f a -> Free f a
eval fa = Bind fa Pure

retract :: Monad f => Free f a -> f a
retract (Pure a   ) = pure a
retract (Bind fx k) = fx >>= (retract . k)

-- unfold :: (v -> f (Either a v)) -> v -> Free f a

fold :: Monad m => (forall x. f x -> m x) -> Free f a -> m a
fold f m = case m of
  Pure a -> pure a
  Bind x k -> f x >>= fold f . k

unfold :: (v -> Either a (f v)) -> v -> Free f a
unfold f seed = case f seed of
  Left a -> Pure a
  Right fv -> Bind fv (unfold f)

unfold' :: (v -> Free f (Either a v)) -> v -> Free f a
unfold' f seed = f seed >>= either Pure (unfold' f)

unfoldM :: (Traversable f, Applicative m, Monad m)
        => (b -> m (Either a (f b))) -> b -> m (Free f a)
unfoldM f seed = do
  e <- f seed
  case e of
    Left a -> pure (Pure a)
    Right fb -> free <$> traverse (unfoldM f) fb

free :: Traversable f => f (Free f a) -> Free f a
free = go . sequence
  where go (Pure fa) = Bind fa Pure
        go (Bind fi f) = Bind fi (go . f)


foldWithIndex :: forall f m a . Monad m => (forall x. Int -> f x -> m x) -> Free f a -> m a
foldWithIndex f m = go 0 f m
  where go :: Int -> (forall x. Int -> f x -> m x) -> Free f a -> m a
        go starting f m = case m of
                            Pure a -> pure a
                            Bind x k -> (f starting x) >>= (go $ starting + 1) f . k


instance Functor (Free f) where
  fmap = liftM

instance Monad (Free f) where
  return = Pure
  Pure a >>= f = f a
  Bind fx f >>= g = Bind fx (f >=> g)

instance Applicative (Free f) where
  pure = Pure
  (<*>) = ap

instance MonadTrans Free where lift = eval

instance MonadFree f (Free f) where
  wrap = join . eval
  {-# INLINE wrap #-}

class Monad m => MonadFreer f m | m -> f where
  wrapF :: f (m a) -> m a
  evalF :: f a -> m a

-- A version of MonadFree that doesn't require Functor
instance MonadFreer f (Free f) where
  wrapF = join . eval
  {-# INLINE wrapF #-}
  evalF = eval
  {-# INLINE evalF #-}

instance MonadFreer f m => MonadFreer f (ReaderT e m) where
  wrapF fm = ReaderT $ \e -> join $ flip runReaderT e <$> evalF fm
  evalF fa = lift $ evalF fa

instance MonadFreer f m => MonadFreer f (Lazy.StateT s m) where
  wrapF fm = Lazy.StateT $ \s -> join $ flip Lazy.runStateT s <$> evalF fm
  evalF fa = lift $ evalF fa

instance MonadFreer f m => MonadFreer f (Strict.StateT s m) where
  wrapF fm = Strict.StateT $ \s -> join $ flip Strict.runStateT s <$> evalF fm
  evalF fa = lift $ evalF fa

instance MonadFreer f m => MonadFreer f (ContT r m) where
  wrapF fm = ContT $ \h -> join $ flip runContT h <$> evalF fm
  evalF fa = lift $ evalF fa

instance MonadFreer f m => MonadFreer f (MaybeT m) where
  wrapF fm = MaybeT . join $ runMaybeT <$> evalF fm
  evalF fa = lift $ evalF fa

instance MonadFreer f m => MonadFreer f (ExceptT e m) where
  wrapF fm = ExceptT . join $ runExceptT <$> evalF fm
  evalF fa = lift $ evalF fa

