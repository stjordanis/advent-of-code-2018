{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- |
-- Module      : AOC2018.Interactive
-- Copyright   : (c) Justin Le 2018
-- License     : BSD3
--
-- Maintainer  : justin@jle.im
-- Stability   : experimental
-- Portability : non-portable
--
-- Run actions regarding challenges, solutions, tests, submissions, viewing
-- prompts, etc.
--
-- Essentially implements the functionality of the main app.
--

module AOC2018.Run (
  -- * Options
    TestSpec(..)
  -- * Runners
  -- ** Run solutions, tests, benchmarks
  , MainRunOpts(..), HasMainRunOpts(..), mainRun, defaultMRO
  -- ** View prompts
  , MainViewOpts(..), HasMainViewOpts(..), mainView
  -- ** Submit answers
  , MainSubmitOpts(..), HasMainSubmitOpts(..), mainSubmit, defaultMSO
  -- * Util
  , withColor
  ) where

import           AOC2018.API
import           AOC2018.Challenge
import           AOC2018.Run.Config
import           AOC2018.Run.Load
import           AOC2018.Solver
import           AOC2018.Util
import           Control.Applicative
import           Control.DeepSeq
import           Control.Exception
import           Control.Lens
import           Control.Monad
import           Control.Monad.Except
import           Criterion
import           Data.Bifunctor
import           Data.Char
import           Data.Finite
import           Data.Map                 (Map)
import           Data.Maybe
import           Data.Time
import           Text.Printf
import qualified Data.Map                 as M
import qualified Data.Map.Merge.Lazy      as M
import qualified Data.Text                as T
import qualified Data.Text.IO             as T
import qualified System.Console.ANSI      as ANSI
import qualified System.Console.Haskeline as H

-- | Specification of parts to test and run
data TestSpec = TSAll
              | TSDayAll  { _tsDay  :: Finite 25     }
              | TSDayPart { _tsSpec :: ChallengeSpec }
  deriving Show

-- | Options for 'mainRun'.
data MainRunOpts = MRO { _mroSpec  :: !TestSpec
                       , _mroTest  :: !Bool     -- ^ Run tests?  (Default: False)
                       , _mroBench :: !Bool     -- ^ Benchmark?  (Default: False)
                       , _mroLock  :: !Bool     -- ^ Lock in answer as correct?  (Default: False)
                       , _mroInput :: !(Map (Finite 25) (Map Char String))  -- ^ Manually supply input.  (Default: 'M.empty')
                       }
  deriving Show

makeClassy ''MainRunOpts

-- | Options for 'mainView'.
newtype MainViewOpts = MVO { _mvoSpec :: ChallengeSpec
                           }
  deriving Show

makeClassy ''MainViewOpts

-- | Options for 'mainSubmit'
data MainSubmitOpts = MSO { _msoSpec  :: !ChallengeSpec
                          , _msoTest  :: !Bool    -- ^ Run tests before submitting?  (Default: True)
                          , _msoForce :: !Bool    -- ^ Force submission even if bad?  (Default: False)
                          , _msoLock  :: !Bool    -- ^ Lock answer if submission succeeded?  (Default: True)
                          }
  deriving Show

makeClassy ''MainSubmitOpts

-- | Default options for 'mainRun'.
defaultMRO :: TestSpec -> MainRunOpts
defaultMRO ts = MRO { _mroSpec  = ts
                    , _mroTest  = False
                    , _mroBench = False
                    , _mroLock  = False
                    , _mroInput = M.empty
                    }

-- | Default options for 'mainSubmit'.
defaultMSO :: ChallengeSpec -> MainSubmitOpts
defaultMSO cs = MSO { _msoSpec  = cs
                    , _msoTest  = True
                    , _msoForce = False
                    , _msoLock  = True
                    }

-- | Run, test, bench.
mainRun
    :: (MonadIO m, MonadError [String] m)
    => Config
    -> MainRunOpts
    -> m ()
mainRun Cfg{..} MRO{..} =  do
    toRun <- case _mroSpec of
      TSAll      -> pure challengeMap
      TSDayAll d -> maybeToEither [printf "Day not yet avaiable: %s" (showDay d)] $
                       M.singleton d <$> M.lookup d challengeMap
      TSDayPart (CS d p) -> do
        ps <- maybeToEither [printf "Day not yet available: %s" (showDay d)] $
                M.lookup d challengeMap
        c  <- maybeToEither [printf "Part not found: %c" p] $
                M.lookup p ps
        pure $ M.singleton d (M.singleton p c)

    void . liftIO . runAll _cfgSession _mroLock _mroInput toRun $ \c inp0 CD{..} -> do
      when _mroTest $ do
        testRes <- mapMaybe fst <$> mapM (uncurry (testCase True c)) _cdTests
        unless (null testRes) $ do
          let (mark, color)
                  | and testRes = ('✓', ANSI.Green)
                  | otherwise   = ('✗', ANSI.Red  )
          withColor ANSI.Vivid color $
            printf "[%c] Passed %d out of %d test(s)\n"
                mark
                (length (filter id testRes))
                (length testRes)

      let inp1 = maybe _cdInput  Right           inp0
          ans1 = maybe _cdAnswer (const Nothing) inp0
      case inp1 of
        Right inp
          | _mroBench -> benchmark (nf (runSomeSolution c) inp)
          | otherwise -> void . testCase False c inp $ ans1
        Left e
          | _mroTest  -> pure ()
          | otherwise -> putStrLn "[INPUT ERROR]" *> mapM_ putStrLn e

-- | View prompt
mainView
    :: (MonadIO m, MonadError [String] m)
    => Config
    -> MainViewOpts
    -> m ()
mainView Cfg{..} MVO{..} = do
    CD{..} <- liftIO $ challengeData _cfgSession _mvoSpec
    pmpt   <- liftEither . first ("[PROMPT ERROR]":) $ _cdPrompt
    liftIO $ do
      putStrLn pmpt
      putStrLn ""

-- | Submit and analyze result
mainSubmit
    :: (MonadIO m, MonadError [String] m)
    => Config
    -> MainSubmitOpts
    -> m ()
mainSubmit Cfg{..} MSO{..} = do
    CD{..} <- liftIO $ challengeData _cfgSession _msoSpec
    dMap   <- maybeToEither [printf "Day not yet available: %d" d'] $
                M.lookup _csDay challengeMap
    c      <- maybeToEither [printf "Part not found: %c" _csPart] $
                M.lookup _csPart dMap
    inp    <- liftEither . first ("[PROMPT ERROR]":) $ _cdInput
    sess   <- HasKey <$> maybeToEither ["ERROR: Session Key Required to Submit"] _cfgSession

    when _msoTest $ do
      testRes <- liftIO $
          mapMaybe fst <$> mapM (uncurry (testCase True c)) _cdTests
      unless (null testRes) $ do
        let (mark, color)
                | and testRes = ('✓', ANSI.Green)
                | otherwise   = ('✗', ANSI.Red  )
        liftIO .  withColor ANSI.Vivid color $
          printf "[%c] Passed %d out of %d test(s)\n"
              mark
              (length (filter id testRes))
              (length testRes)
        unless (and testRes) $
          if _msoForce
            then liftIO $ putStrLn "Proceeding with submission despite test failures (--force)"
            else do
              conf <- liftIO . H.runInputT H.defaultSettings $
                H.getInputChar "Some tests failed. Are you sure you wish to proceed? y/(n)"
              case toLower <$> conf of
                Just 'y' -> pure ()
                _        -> throwError ["Submission aborted."]

    resEither <- liftIO . evaluate . force . runSomeSolution c $ inp
    res       <- liftEither . first (("[SOLUTION ERROR]":) . (:[]) . show) $ resEither
    liftIO $ printf "Submitting solution: %s\n" res

    (resp, status) <- liftEither =<< liftIO (runAPI sess (ASubmit _csDay _csPart res))
    let resp' = formatResp resp
        (color, lock, out) = case status of
          SubCorrect -> (ANSI.Green  , True , "Answer was correct!"          )
          SubWrong   -> (ANSI.Red    , False, "Answer was incorrect!"        )
          SubWait    -> (ANSI.Yellow , False, "Answer re-submitted too soon.")
          SubInvalid -> (ANSI.Blue   , False, "Submission was rejected.  Maybe not unlocked yet, or already answered?")
          SubUnknown -> (ANSI.Magenta, False, "Response from server was not recognized.")
    liftIO $ do
      withColor ANSI.Vivid color $
        putStrLn out
      putStrLn resp'
      when lock $
        if _msoLock
          then putStrLn "Locking correct answer." >> writeFile _cpAnswer res
          else putStrLn "Not locking correct answer (--no-lock)"
      zt <- getZonedTime
      appendFile _cpLog $ printf logFmt (show zt) res (showSubmitRes status) resp'
  where
    CS{..} = _msoSpec
    CP{..} = challengePaths _msoSpec
    d' = getFinite _csDay + 1
    formatResp = T.unpack . T.intercalate "\n" . map ("> " <>) . T.lines
    logFmt = unlines [ "[%s]"
                        , "Submission: %s"
                        , "Status: %s"
                        , "%s"
                        ]

runAll
    :: Maybe String       -- ^ session key
    -> Bool               -- ^ run and lock answer
    -> Map (Finite 25) (Map Char String)        -- ^ replacements
    -> ChallengeMap
    -> (SomeSolution -> Maybe String -> ChallengeData -> IO a)  -- ^ callback. given solution, "replacement" input, and data
    -> IO (Map (Finite 25) (Map Char a))
runAll sess lock rep cm f = flip M.traverseWithKey cm' $ \d ->
                            M.traverseWithKey $ \p (inp0, c) -> do
    let CP{..} = challengePaths (CS d p)
    withColor ANSI.Dull ANSI.Blue $
      printf ">> Day %02d%c\n" (getFinite d + 1) p
    when lock $ do
      CD{..} <- challengeData sess (CS d p)
      forM_ (inp0 <|> eitherToMaybe _cdInput) $ \inp ->
        mapM_ (writeFile _cpAnswer) =<< evaluate (force (runSomeSolution c inp))
    f c inp0 =<< challengeData sess (CS d p)
  where
    cm' = pushMap $ M.merge M.dropMissing
                            (M.mapMissing     $ \_   c -> (Nothing, c))
                            (M.zipWithMatched $ \_ r c -> (Just r , c))
                            (pullMap rep)
                            (pullMap cm)

pullMap
    :: Map a (Map b c)
    -> Map (a, b) c
pullMap = M.fromDistinctAscList
        . concatMap (uncurry go . second M.toAscList)
        . M.toAscList
  where
    go x = (map . first) (x,)

pushMap
    :: Eq a
    => Map (a, b) c
    -> Map a (Map b c)
pushMap = fmap M.fromDistinctAscList
        . M.fromAscListWith (++)
        . map (uncurry go)
        . M.toAscList
  where
    go (x, y) z = (x, [(y, z)])

testCase
    :: Bool             -- ^ is just an example
    -> SomeSolution
    -> String
    -> Maybe String
    -> IO (Maybe Bool, Either SolutionError String)
testCase emph c inp ans = do
    withColor ANSI.Dull color $
      printf "[%c]" mark
    if emph
      then printf " (%s)\n" resStr
      else printf " %s\n"   resStr
    forM_ showAns $ \a -> do
      withColor ANSI.Vivid ANSI.Red $
        printf "(Expected: %s)\n" a
    return (status, res)
  where
    res = runSomeSolution c inp
    resStr = case res of
      Right r -> r
      Left SEParse -> "ERROR: No parse"
      Left SESolve -> "ERROR: No solution"
    (mark, showAns, status) = case ans of
      Just (strip->ex)    -> case res of
        Right (strip->r)
          | r == ex   -> ('✓', Nothing, Just True )
          | otherwise -> ('✗', Just ex, Just False)
        Left _        -> ('✗', Just ex, Just False)
      Nothing             -> ('?', Nothing, Nothing   )
    color = case status of
      Just True  -> ANSI.Green
      Just False -> ANSI.Red
      Nothing    -> ANSI.Blue

-- | Do the action with a given ANSI foreground color and intensity.
withColor
    :: ANSI.ColorIntensity
    -> ANSI.Color
    -> IO ()
    -> IO ()
withColor ci c act = do
    ANSI.setSGR [ ANSI.SetColor ANSI.Foreground ci c ]
    act
    ANSI.setSGR [ ANSI.Reset ]
