{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Infer
  ( infer
  , infer'
  ) where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.ST
import Data.Coerce
import Data.Foldable
import Data.Functor qualified as Functor
import Data.Map.Merge.Lazy qualified as Map

import Error
import Exp as Exp
import FA
import Head as Head
import Map.Lazy (Map)
import Map.Lazy qualified as Map
import Name
import Ref
import Set (Set)
import Set qualified
import State qualified
import Supply
import Unify

type Mono = DFA HeadMap

type Poly a = (Map a Mono, Mono)

type MMono r = NFA r HeadMap

type MPoly a r = (Map a (MMono r), MMono r)

infer :: ( Ord a
         , MonadError Error m
         , MonadFix m
         , MonadReader (Map a (Poly a)) m
         , MonadRef r m
         , MonadSupply Label m
         ) => Exp a -> m (MPoly a r)
infer = \ case
  Var x -> Map.lookup x <$> ask >>= \ case
    Just t -> thaw t
    Nothing -> mdo
      t_neg <- newNFA State.empty mempty (Set.singleton t_pos)
      t_pos <- newNFA State.empty mempty (Set.singleton t_neg)
      pure (Map.singleton x t_neg, t_pos)
  Abs xs e ->
    inferAbs xs e
  App e1 e2 -> mdo
    (env_e1, t_e1) <- infer e1
    (env_e2, t_e2) <- infer e2
    t_neg <- newNFA State.empty mempty (Set.singleton t_pos)
    t_pos <- newNFA State.empty mempty (Set.singleton t_neg)
    unify' t_e1 =<< freshFn t_e2 t_neg
    (, t_pos) <$> union env_e1 env_e2
  Val x e1 e2 -> do
    t_e1 <- freeze =<< infer e1
    local (Map.insert x t_e1) $ infer e2
  Exp.Fn x xs e1 e2 -> do
    t_e1 <- freeze =<< inferAbs xs e1
    local (Map.insert x t_e1) $ infer e2
  Seq e1 e2 -> do
    (env_e1, _) <- infer e1
    (env_e2, t_e2) <- infer e2
    (, t_e2) <$> union env_e1 env_e2
  Block e -> do
    (env, t_e) <- infer e
    t_x <- freshVoid
    (env,) <$> freshFn t_x t_e
  Exp.Struct x xs -> do
    (env, xs) <- forAccumLM mempty xs $ \ env (i, e) -> do
      (env_e, t_e) <- infer e
      (, (i, Set.singleton t_e)) <$> union env env_e
    (env,) <$> freshStruct x xs
  Field e i -> mdo
    (env_e, t_e) <- infer e
    t_neg <- newNFA State.empty mempty (Set.singleton t_pos)
    t_pos <- newNFA State.empty mempty (Set.singleton t_neg)
    unify' t_e =<< freshField i t_neg
    pure (env_e, t_pos)
  Switch e@(Var v) x xs y -> do
    (env_e, t_e_pos) <- infer e
    z <- do
      let (i, e) = x
      (env_e, t_e, t_i) <- inferVarCase v i e
      pure (env_e, t_e, [(i, Just (Set.singleton t_i))])
    (env_xs, t_xs, t_i) <- rotate foldlM z xs $ \ (env_xs, t_xs, z) (i, e) -> do
      (env_e, t_e, t_i) <- inferVarCase v i e
      (,, (i, Just (Set.singleton t_i)):z) <$> union env_xs env_e <*> append t_xs t_e
    (env_y, t_y, t_def) <- funzip3 <$> traverse (inferVarDefault v (fst <$> t_i)) y
    t_e_neg <- freshUnion t_i t_def
    unify' t_e_pos t_e_neg
    (,) <$>
      (maybe pure (flip union) env_y =<< union env_e env_xs) <*>
      maybe pure (flip append) t_y t_xs
  Switch e x xs y -> do
    (env_e, t_e_pos) <- infer e
    z <- do
      let (i, e) = x
      (env_e, t_e) <- infer e
      t_i <- Set.singleton <$> fresh State.empty
      pure (env_e, t_e, [(i, Just t_i)])
    (env_xs, t_xs, t_i) <- rotate foldlM z xs $ \ (env_xs, t_xs, z) (i, e) -> do
      (env_e, t_e) <- infer e
      t_i <- fresh State.empty
      (,, (i, Just (Set.singleton t_i)):z) <$> union env_xs env_e <*> append t_xs t_e
    (env_def, t_y) <- funzip <$> traverse infer y
    t_e_neg <- freshUnion t_i . Just =<< fresh State.empty
    unify' t_e_pos t_e_neg
    (,) <$>
      (maybe pure (flip union) env_def =<< union env_e env_xs) <*>
      maybe pure (flip append) t_y t_xs
  Enum i ->
    (mempty,) <$> (freshCase i =<< fresh (State.singleton Head.Void))
  Exp.Void ->
    (mempty,) <$> freshVoid

inferAbs :: ( Ord a
            , Foldable t
            , MonadError Error m
            , MonadFix m
            , MonadReader (Map a (Poly a)) m
            , MonadRef r m
            , MonadSupply Label m
            ) => t a -> Exp a -> m (MPoly a r)
inferAbs xs e = do
  z <- local (Map.deleteAll xs) $ infer e
  rotate foldrM z xs $ \ x (env, t) ->
    case Map.lookup x env of
      Just t_x ->
        (Map.delete x env,) <$> freshFn t_x t
      Nothing -> do
        t_x <- fresh State.empty
        (env,) <$> freshFn t_x t

inferVarCase :: ( Ord a
                , MonadError Error m
                , MonadFix m
                , MonadReader (Map a (Poly a)) m
                , MonadRef r m
                , MonadSupply Label m
                ) => a -> Name -> Exp a -> m (Map a (MMono r), MMono r, MMono r)
inferVarCase v i e = do
  (env_e, t_e) <- infer e
  case Map.lookup v env_e of
    Just t_neg -> mdo
      t_i_neg <- newNFA State.empty mempty (Set.singleton t_i_pos)
      t_i_pos <- newNFA State.empty mempty (Set.singleton t_i_neg)
      t_pos <- freshCase i t_i_pos
      unify' t_pos t_neg
      pure (Map.delete v env_e, t_e, t_i_neg)
    Nothing -> do
      t_i_neg <- fresh State.empty
      pure (env_e, t_e, t_i_neg)

inferVarDefault :: ( Ord a
                   , MonadError Error m
                   , MonadFix m
                   , MonadReader (Map a (Poly a)) m
                   , MonadRef r m
                   , MonadSupply Label m
                   ) => a -> [Name] -> Exp a -> m (Map a (MMono r), MMono r, MMono r)
inferVarDefault v i e = do
  (env_e, t_e) <- infer e
  case Map.lookup v env_e of
    Just t_neg -> mdo
      t_i_neg <- newNFA State.empty mempty (Set.singleton t_i_pos)
      t_i_pos <- newNFA State.empty mempty (Set.singleton t_i_neg)
      t_pos <- freshDefault i t_i_pos
      unify' t_pos t_neg
      pure (Map.delete v env_e, t_e, t_i_neg)
    Nothing -> do
      t_i_neg <- fresh State.empty
      pure (env_e, t_e, t_i_neg)

newtype UnifyErrorT m a =
  UnifyErrorT { runUnifyErrorT :: m a
              } deriving (Functor, Applicative, Monad, MonadFix)

deriving instance MonadRef r m => MonadRef r (UnifyErrorT m)

instance MonadTrans UnifyErrorT where
  lift = UnifyErrorT

instance MonadError Error m => MonadUnifyError HeadMap (UnifyErrorT m) where
  throwUnifyError x y =
    lift $ throwError $ UnifyError (Functor.void x) (Functor.void y)

unify' :: ( MonadError Error m
          , MonadFix m
          , MonadRef r m
          ) => MMono r -> MMono r -> m ()
unify' x y = runUnifyErrorT (unify x y)

newtype StateL s f a = StateL { runStateL :: s -> f (s, a) }

instance Functor f => Functor (StateL s f) where
  fmap f m = StateL $ fmap (fmap f) . coerce m

instance Monad f => Applicative (StateL s f) where
  pure x = StateL $ pure . (, x)
  f <*> x = StateL $ \ s -> runStateL f s >>= \ (s, f) -> fmap f <$> runStateL x s

forAccumLM :: forall t f a b c .
              ( Traversable t
              , Monad f
              ) => b -> t a -> (b -> a -> f (b, c)) -> f (b, t c)
forAccumLM s t f = coerce (traverse @t @(StateL b f) @a @c) (flip f) t s

infer' :: Ord a => Exp a -> Either Error (Poly a)
infer' e = runST (runSupplyT (runReaderT (runExceptT (infer e >>= freeze)) mempty))

union :: ( Ord a
         , State.Map t
         , MonadRef r m
         , MonadSupply Label m
         ) => Map a (NFA r t) -> Map a (NFA r t) -> m (Map a (NFA r t))
union =
  Map.mergeA Map.preserveMissing Map.preserveMissing $
  Map.zipWithAMatched $ const append

append :: ( State.Map t
          , MonadRef r m
          , MonadSupply Label m
          ) => NFA r t -> NFA r t -> m (NFA r t)
append x y = newNFA State.empty (Set.fromList [x, y]) mempty

fresh :: ( State.Map t
         , MonadRef r m
         , MonadSupply Label m
         ) => t (Set (NFA r t)) -> m (NFA r t)
fresh x = newNFA x mempty mempty

freshFn :: ( MonadRef r m
           , MonadSupply Label m
           ) => MMono r -> MMono r -> m (MMono r)
freshFn x y =
  freshAll =<< fresh (State.singleton (Head.Fn (Set.singleton x) (Set.singleton y)))

freshStruct :: ( MonadRef r m
               , MonadSupply Label m
               ) => Maybe Name -> [(Name, Set (MMono r))] -> m (MMono r)
freshStruct x =
  (maybe freshAll freshCase x =<<) . fresh . State.singleton . Head.Struct . Map.fromList

freshField :: ( MonadRef r m
              , MonadSupply Label m
              ) => Name -> MMono r -> m (MMono r)
freshField i x =
  freshAll =<< fresh (State.singleton (Head.Struct (Map.singleton i (Set.singleton x))))

freshUnion :: ( MonadRef r m
              , MonadSupply Label m
              ) => [(Name, Maybe (Set (MMono r)))] -> Maybe (MMono r) -> m (MMono r)
freshUnion xs =
  fresh . State.singleton . Union (Map.fromList xs) . fmap Set.singleton

freshCase :: ( MonadRef r m
             , MonadSupply Label m
             ) => Name -> MMono r -> m (MMono r)
freshCase i =
  fresh . State.singleton . flip Union Nothing . Map.singleton i . Just . Set.singleton


freshDefault :: ( MonadRef r m
                , MonadSupply Label m
                ) => [Name] -> MMono r -> m (MMono r)
freshDefault i =
  fresh . State.singleton . Union (Map.fromList ((, Nothing) <$> i)) . Just . Set.singleton

freshAll :: ( MonadRef r m
            , MonadSupply Label m
            ) => MMono r -> m (MMono r)
freshAll =
  fresh . State.singleton . Union mempty . Just . Set.singleton

freshVoid :: ( MonadRef r m
             , MonadSupply Label m
             ) => m (MMono r)
freshVoid =
  freshAll =<< fresh (State.singleton Head.Void)

freeze :: ( MonadFix m
          , MonadRef r m
          ) => MPoly a r -> m (Poly a)
freeze (env, t) = evalFreezeT $ (,) <$> traverse fromNegNFA env <*> fromPosNFA t

thaw :: ( MonadFix m
        , MonadSupply Label m
        , MonadRef r m
        ) => Poly a -> m (MPoly a r)
thaw (env, t) = evalThawT $ (,) <$> traverse fromDFA env <*> fromDFA t

newNFA :: ( MonadRef r m
          , MonadSupply Label m
          ) => t (Set (NFA r t)) -> Set (NFA r t) -> Set (NFA r t) -> m (NFA r t)
newNFA trans epsilonTrans flow =
  NFA <$> supply <*> newRef trans <*> newRef epsilonTrans <*> newRef flow

funzip :: Functor f => f (a, b) -> (f a, f b)
funzip x = (fst <$> x, snd <$> x)

funzip3 :: Functor f => f (a, b, c) -> (f a, f b, f c)
funzip3 x = ((\ (x, _, _) -> x) <$> x, (\ (_, x, _) -> x) <$> x, (\ (_, _, x) -> x) <$> x)

rotate :: (a -> b -> c -> d) -> b -> c -> a -> d
rotate f b c a = f a b c
