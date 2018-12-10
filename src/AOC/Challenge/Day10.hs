{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : AOC.Challenge.Day10
-- Copyright   : (c) Justin Le 2018
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Day 10.  See "AOC.Solver" for the types used in this module!

module AOC.Challenge.Day10 (
    day10a
  , day10b
  ) where

import           AOC.Common     (clearOut)
import           AOC.Solver     ((:~>)(..))
import           Control.Monad  (guard)
import           Data.Bifunctor (second)
import           Data.Char      (isDigit)
import           Data.Foldable  (toList, foldMap)
import           Data.List      (unfoldr, uncons)
import           Data.Map       (Map)
import           Data.Maybe     (catMaybes)
import           Data.Semigroup (Min(..), Max(..))
import           Data.Set       (Set)
import           Linear         (V2(..))
import           Text.Heredoc   (here)
import qualified Data.Map       as M
import qualified Data.Set       as S

type Point = V2 Int

simulate
    :: [Point]        -- ^ velocities
    -> [Point]        -- ^ points
    -> [Point]        -- ^ new points
simulate = zipWith (+)

boundingBox :: [Point] -> V2 Point
boundingBox ps = V2 xMin yMin `V2` V2 xMax yMax
  where
    (Min xMin, Min yMin, Max xMax, Max yMax) = flip foldMap ps $ \(V2 x y) ->
        (Min x, Min y, Max x, Max y)

clusterArea :: [Point] -> Int
clusterArea (boundingBox -> V2 mins maxs) = product $ maxs - mins

findWord
    :: [Point]            -- ^ velocities
    -> [Point]            -- ^ points
    -> (Set Point, Int)   -- ^ points in word, and # of iterations
findWord vs xs0 = go 0 (clusterArea xs0) xs0
  where
    go :: Int -> Int -> [Point] -> (Set Point, Int)
    go !i !area !xs
        | area' > area = (S.fromList xs, i)
        | otherwise    = go (i + 1) area' xs'
      where
        xs'   = simulate vs xs
        area' = clusterArea xs'

day10a :: ([Point], [Point]) :~> Set Point
day10a = MkSol
    { sParse = fmap unzip . traverse parsePoint . lines
    , sShow  = parseResult
    , sSolve = Just . fst . uncurry findWord
    }

day10b :: ([Point], [Point]) :~> Int
day10b = MkSol
    { sParse = fmap unzip . traverse parsePoint . lines
    , sShow  = show
    , sSolve = Just . snd . uncurry findWord
    }

-- | Old solution: Display the points as ASCII plot
_display :: Set Point -> String
_display ps = unlines [ [ if V2 x y `S.member` ps then '#' else '.'
                       | x <- [xMin .. xMax]
                       ]
                     | y <- [yMin .. yMax]
                     ]
  where
    V2 xMin yMin `V2` V2 xMax yMax = boundingBox (toList ps)

-- | New solution: Parse the set of points into a string, based on
-- 'letterforms'.
parseResult :: Set Point -> String
parseResult ps = case M.lookup letter letterMap of
    Nothing -> []
    Just c  -> c : parseResult rest
  where
    origin `V2` _  = boundingBox (toList ps)
    shiftedPs      = subtract origin `S.map` ps
    (letter, rest) = S.partition (\(V2 x y) -> x < 6 && y < 10) shiftedPs

parsePoint :: String -> Maybe (Point, Point)
parsePoint xs = case map read . words . clearOut p $ xs of
    [x,y,vx,vy] -> Just (V2 vx vy, V2 x y)
    _           -> Nothing
  where
    p '-' = False
    p c   = not $ isDigit c

-- | A map of a set of "on" points (for a 6x10 grid) to the letter
-- they represent
letterMap :: Map (Set Point) Char
letterMap = M.fromList
          . unfoldr (uncurry peel)
          . second (filter (not . null) . lines)
          $ letterforms
  where
    peel :: String -> [String] -> Maybe ((Set Point, Char), (String, [String]))
    peel cs ls = do
      (d,ds) <- uncons cs
      let (m,ms) = unzip . map (splitAt 6) $ ls
          pointMap = S.fromList
                   . foldMap catMaybes
                   . zipWith (\j -> zipWith (\i c -> V2 i j <$ guard (c == '#'))
                                            [0..]
                             )
                             [0..]
                   $ m
      pure ((pointMap, d), (ds, ms))

-- | All known letterforms.  Based on
-- <https://gist.github.com/usbpc/5fa0be48ad7b4b0594b3b8b029bc47b4>.
letterforms :: (String, String)
letterforms = ("ABCEFGHJKLNPRXZ",[here|
..##..#####..####.############.####.#....#...####....##.....#....######.#####.#....#######
.#..#.#....##....##.....#.....#....##....#....#.#...#.#.....##...##....##....##....#.....#
#....##....##.....#.....#.....#.....#....#....#.#..#..#.....##...##....##....#.#..#......#
#....##....##.....#.....#.....#.....#....#....#.#.#...#.....#.#..##....##....#.#..#.....#.
#....######.#.....#####.#####.#.....######....#.##....#.....#.#..######.#####...##.....#..
#######....##.....#.....#.....#..####....#....#.##....#.....#..#.##.....#..#....##....#...
#....##....##.....#.....#.....#....##....#....#.#.#...#.....#..#.##.....#...#..#..#..#....
#....##....##.....#.....#.....#....##....##...#.#..#..#.....#...###.....#...#..#..#.#.....
#....##....##....##.....#.....#...###....##...#.#...#.#.....#...###.....#....##....##.....
#....######..####.#######......###.##....#.###..#....########....##.....#....##....#######
|])