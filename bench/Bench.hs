
import           AOC2018
import           Control.Monad.Except

main :: IO ()
main = do
    cfg <- configFile defConfPath
    void . runExceptT . mainRun cfg $ (defaultMRO TSAll)
        { _mroBench = True
        }
