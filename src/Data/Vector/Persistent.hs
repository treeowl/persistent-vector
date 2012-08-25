-- | This is a port of the persistent vector from clojure to Haskell.
--
-- The implementation is based on array mapped tries.
--
-- TODO:
--
-- * Implement pop (remove last element)
module Data.Vector.Persistent (
  Vector,
  empty,
  null,
  length,
  singleton,
  index,
  unsafeIndex,
  snoc,
  -- * Conversion
  fromList
  ) where

import Prelude hiding ( null, length, tail )

import Control.Applicative hiding ( empty )
import Control.DeepSeq
import Data.Bits
import Data.Foldable ( Foldable )
import qualified Data.Foldable as F
import Data.Monoid ( Monoid )
import qualified Data.Monoid as M
import Data.Traversable ( Traversable )
import qualified Data.Traversable as T

import Data.Vector.Persistent.Array ( Array )
import qualified Data.Vector.Persistent.Array as A

-- Note: using Int here doesn't give the full range of 32 bits on a 32
-- bit machine (it is fine on 64)
data Vector a = EmptyVector
              | RootNode { vecSize :: !Int
                         , vecShift :: !Int
                         , vecTail :: !(Array a)
                         , intVecPtrs :: !(Array (Vector a))
                         }
              | InternalNode { intVecPtrs :: !(Array (Vector a))
                             }
              | DataNode { dataVec :: !(Array a)
                         }
              deriving (Eq, Ord, Show)

instance Foldable Vector where
  foldr = pvFoldr

instance Functor Vector where
  fmap = pvFmap

instance Monoid (Vector a) where
  mempty = empty
  mappend = pvAppend

instance Traversable Vector where
  traverse = pvTraverse

instance (NFData a) => NFData (Vector a) where
  rnf = pvRnf

{-# INLINABLE pvFmap #-}
pvFmap :: (a -> b) -> Vector a -> Vector b
pvFmap f = go
  where
    go EmptyVector = EmptyVector
    go (DataNode v) = DataNode (A.map f v)
    go (InternalNode v) = InternalNode (A.map (fmap f) v)
    go (RootNode sz sh t v) =
      let t' = A.map f t
          v' = A.map (fmap f) v
      in RootNode sz sh t' v'

{-# INLINABLE pvFoldr #-}
pvFoldr :: (a -> b -> b) -> b -> Vector a -> b
pvFoldr f = go
  where
    go seed EmptyVector = seed
    go seed (DataNode a) = {-# SCC "goDataNode" #-} A.foldr f seed a
    go seed (InternalNode as) = {-# SCC "goInternalNode" #-}
      A.foldr (flip go) seed as
    go seed (RootNode _ _ t as) = {-# SCC "goRootNode" #-}
      let tseed = A.foldr f seed t
      in A.foldr (flip go) tseed as

{-# INLINABLE pvTraverse #-}
pvTraverse :: (Applicative f) => (a -> f b) -> Vector a -> f (Vector b)
pvTraverse f = go
  where
    go EmptyVector = pure EmptyVector
    go (DataNode a) = DataNode <$> A.traverse f a
    go (InternalNode as) = InternalNode <$> A.traverse go as
    go (RootNode sz sh t as) =
      RootNode sz sh <$> A.traverse f t <*> A.traverse go as

{-# INLINABLE pvAppend #-}
pvAppend :: Vector a -> Vector a -> Vector a
pvAppend EmptyVector v = v
pvAppend v EmptyVector = v
pvAppend v1 v2 = F.foldl' snoc v1 (F.toList v2)

{-# INLINABLE pvRnf #-}
pvRnf :: (NFData a) => Vector a -> ()
pvRnf EmptyVector = ()
pvRnf (DataNode a) = rnf a
pvRnf (InternalNode a) = rnf a
pvRnf (RootNode _ _ t as) = rnf as `seq` rnf t

-- Functions

empty :: Vector a
empty = EmptyVector

null :: Vector a -> Bool
null EmptyVector = True
null _ = False

length :: Vector a -> Int
length EmptyVector = 0
length RootNode { vecSize = s } = s
length InternalNode {} = error "Internal nodes should not be exposed"
length DataNode {} = error "Data nodes should not be exposed"

index :: Vector a -> Int -> Maybe a
index v ix
  | length v > ix = Just $ unsafeIndex v ix
  | otherwise = Nothing

unsafeIndex :: Vector a -> Int -> a
unsafeIndex vec ix
  | ix >= tailOffset vec =
    A.index (vecTail vec) (ix .&. 0x1f)
  | otherwise = go (fromIntegral (vecShift vec)) vec
  where
    wordIx = fromIntegral ix
    go level v
      | level == 0 = A.index (dataVec v) (wordIx .&. 0x1f)
      | otherwise =
        let nextVecIx = (wordIx `shiftR` level) .&. 0x1f
            v' = intVecPtrs v
        in go (level - 5) (A.index v' nextVecIx)

singleton :: a -> Vector a
singleton elt =
  RootNode { vecSize = 1
           , vecShift = 5
           , vecTail = A.fromList 1 [elt]
           , intVecPtrs = A.fromList 0 []
           }

arraySnoc :: Array a -> a -> Array a
arraySnoc a elt = A.run $ do
  let alen = A.length a
  a' <- A.new_ (1 + alen)
  A.copy a 0 a' 0 alen
  A.write a' alen elt
  return a'

snoc :: Vector a -> a -> Vector a
snoc EmptyVector elt = singleton elt
snoc v@RootNode { vecSize = sz, vecShift = sh, vecTail = t } elt
  -- Room in tail
  | not (nodeIsFull t) = v { vecTail = arraySnoc t elt, vecSize = sz + 1 }
  -- Overflow current root
  | sz `shiftR` 5 > 1 `shiftL` sh =
    RootNode { vecSize = sz + 1
             , vecShift = sh + 5
             , vecTail = A.fromList 1 [elt]
             , intVecPtrs = A.fromList 2 [ InternalNode (intVecPtrs v)
                                         , newPath sh t
                                         ]
             }
  -- Insert into the tree
  | otherwise =
      RootNode { vecSize = sz + 1
               , vecShift = sh
               , vecTail = A.fromList 1 [elt]
               , intVecPtrs = pushTail sz t sh (intVecPtrs v)
               }
snoc _ _ = error "Internal nodes should not be exposed to the user"

pushTail :: Int -> Array a -> Int -> Array (Vector a) -> Array (Vector a)
pushTail cnt t = go
  where
    go level parent
      | level == 5 = arraySnoc parent (DataNode t)
      | subIdx < A.length parent =
        let nextVec = A.index parent subIdx
            toInsert = go (level - 5) (intVecPtrs nextVec)
        in A.update parent subIdx (InternalNode toInsert)
--         parent V.// [(subIdx, InternalNode toInsert)]
      | otherwise = arraySnoc parent (newPath (level - 5) t)
      where
        subIdx = ((cnt - 1) `shiftR` level) .&. 0x1f

newPath :: Int -> Array a -> Vector a
newPath level t
  | level == 0 = DataNode t
  | otherwise = InternalNode $ A.fromList 1 $ [newPath (level - 5) t]


tailOffset :: Vector a -> Int
tailOffset v
  | len < 32 = 0
  | otherwise = (len - 1) `shiftR` 5 `shiftL` 5
  where
    len = length v

nodeIsFull :: Array a -> Bool
nodeIsFull = (==32) . A.length

fromList :: [a] -> Vector a
fromList = F.foldl' snoc empty
