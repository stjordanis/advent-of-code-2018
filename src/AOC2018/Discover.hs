{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : AOC2018.Discover
-- Copyright   : (c) Justin Le 2018
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Template Haskell for discovering all named challenges in a given
-- directory.
--

module AOC2018.Discover (
    mkSolutionMap
  , solutionList
  ) where

import           AOC2018.Challenge
import           Data.Bifunctor
import           Data.Data
import           Data.Finite
import           Data.Maybe
import           Data.Traversable
import           Data.Void
import           Language.Haskell.Exts      as E
import           Language.Haskell.Names
import           Language.Haskell.TH        as TH
import           Language.Haskell.TH.Syntax (TExp(..))
import           Prelude
import           System.Directory
import           System.FilePath
import           Text.Printf
import           Text.Read                  (readMaybe)
import qualified Data.Map                   as M
import qualified Hpack.Config               as H
import qualified Text.Megaparsec            as P
import qualified Text.Megaparsec.Char       as P

type Parser = P.Parsec Void String

-- | Template Haskell splice to produce a list of all named solutions in
-- a directory. Expects solutions as function names following the format
-- @dayDDp@, where @DD@ is a two-digit zero-added day, and @p@ is
-- a lower-case letter corresponding to the part of the challenge.
--
-- See 'mkSolutionMap' for a description of usage.
solutionList :: FilePath -> Q (TExp [(Finite 25, (Char, SomeSolution))])
solutionList dir = TExp
                  . ListE
                  . map (unType . specExp)
                <$> runIO (getChallengeSpecs dir)


-- | Meant to be called like:
--
-- @
-- mkSolutionMap $$(solutionList "src\/AOC2018\/Challenge")
-- @
mkSolutionMap :: [(Finite 25, (Char, SomeSolution))] -> SolutionMap
mkSolutionMap = M.unionsWith M.union
               . map (uncurry M.singleton . second (uncurry M.singleton))


specExp :: ChallengeSpec -> TExp (Finite 25, (Char, SomeSolution))
specExp s@(CS d p) = TExp $ TupE
    [ LitE (IntegerL (getFinite d))
    , TupE
        [ LitE (CharL p)
        , ConE 'MkSomeSol `AppE` VarE (mkName (specName s))
        ]
    ]

specName :: ChallengeSpec -> String
specName (CS d p) = printf "day%02d%c" (getFinite d + 1) p

getChallengeSpecs
    :: FilePath                 -- ^ directory of modules
    -> IO [ChallengeSpec]       -- ^ all challenge specs found
getChallengeSpecs dir = do
    exts   <- defaultExtensions
    files  <- listDirectory dir
    parsed <- forM files $ \f -> do
      let mode = defaultParseMode { extensions    = exts
                                  , fixities      = Just []
                                  , parseFilename = f
                                  }
      res <- parseFileWithMode mode (dir </> f)
      case res of
        ParseOk x       -> pure x
        ParseFailed l e -> fail $ printf "Failed parsing %s at %s: %s" f (show l) e
    pure $ moduleChallenges parsed

defaultExtensions :: IO [E.Extension]
defaultExtensions = do
    Right (H.DecodeResult{..}) <- H.readPackageConfig H.defaultDecodeOptions
    Just H.Section{..} <- pure $ H.packageLibrary decodeResultPackage
    pure $ parseExtension <$> sectionDefaultExtensions

moduleChallenges :: (Data l, Eq l) => [Module l] -> [ChallengeSpec]
moduleChallenges = (foldMap . foldMap) (maybeToList . isSolution)
                 . flip resolve M.empty


isSolution :: Symbol -> Maybe ChallengeSpec
isSolution s = do
    Value _ (Ident _ n) <- pure s
    Right c             <- pure $ P.runParser challengeName "" n
    pure c

challengeName :: Parser ChallengeSpec
challengeName = do
    _    <- P.string "day"
    dStr <- P.many P.numberChar
    dInt <- case readMaybe dStr of
      Just i  -> pure (i - 1)
      Nothing -> fail "Failed parsing integer"
    dFin <- case packFinite dInt of
      Just i  -> pure i
      Nothing -> fail $ "Day not in range: " ++ show dInt
    c    <- P.lowerChar
    pure $ CS dFin c
