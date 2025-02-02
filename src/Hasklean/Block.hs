--------------------------------------------------------------------------------
{-# HLINT ignore "Redundant if"                        #-}
{-# LANGUAGE ImportQualifiedPost                       #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas              #-}
module Hasklean.Block
    ( Block(..)
    , LineBlock
    , SpanBlock
    , adjacent
    , blockLength
    , groupAdjacent
    , merge
    , mergeAdjacent
    , moveBlock
    , overlapping
    , realSrcSpanToLineBlock
    ) where


--------------------------------------------------------------------------------
import Data.IntSet qualified as IS
import GHC.Types.SrcLoc qualified as GHC


--------------------------------------------------------------------------------
-- | Indicates a line span
data Block a = Block
    { blockStart :: Int
    , blockEnd   :: Int
    } deriving (Eq, Ord, Show)


--------------------------------------------------------------------------------
instance Semigroup (Block a) where
    (<>) = merge


--------------------------------------------------------------------------------
type LineBlock = Block String


--------------------------------------------------------------------------------
type SpanBlock = Block Char


--------------------------------------------------------------------------------
realSrcSpanToLineBlock :: GHC.RealSrcSpan -> Block String
realSrcSpanToLineBlock s = Block (GHC.srcSpanStartLine s) (GHC.srcSpanEndLine s)


--------------------------------------------------------------------------------
blockLength :: Block a -> Int
blockLength (Block start end) = end - start + 1


--------------------------------------------------------------------------------
moveBlock :: Int -> Block a -> Block a
moveBlock offset (Block start end) = Block (start + offset) (end + offset)


--------------------------------------------------------------------------------
adjacent :: Block a -> Block a -> Bool
adjacent b1 b2 = follows b1 b2 || follows b2 b1
  where
    follows (Block _ e1) (Block s2 _) = e1 == s2 || e1 + 1 == s2


--------------------------------------------------------------------------------
merge :: Block a -> Block a -> Block a
merge (Block s1 e1) (Block s2 e2) = Block (min s1 s2) (max e1 e2)


--------------------------------------------------------------------------------
overlapping :: [Block a] -> Bool
overlapping = go IS.empty
  where
    go _   []       = False
    go acc (b : bs) =
        let ints = [blockStart b .. blockEnd b] in
        if any (`IS.member` acc) ints
            then True
            else go (IS.union acc $ IS.fromList ints) bs


--------------------------------------------------------------------------------
-- | Groups adjacent blocks into larger blocks
groupAdjacent :: [(Block a, b)]
              -> [(Block a, [b])]
groupAdjacent = foldr go []
  where
    -- This code is ugly and not optimal, and no fucks were given.
    go (b1, x) gs = case break (adjacent b1 . fst) gs of
        (_, [])               -> (b1, [x]) : gs
        (ys, (b2, xs) : zs) -> (merge b1 b2, x : xs) : (ys ++ zs)

mergeAdjacent :: [Block a] -> [Block a]
mergeAdjacent (a : b : rest) | a `adjacent` b = merge a b : mergeAdjacent rest
mergeAdjacent (a : rest)     = a : mergeAdjacent rest
mergeAdjacent []             = []
