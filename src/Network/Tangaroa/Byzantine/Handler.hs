{-# LANGUAGE RecordWildCards #-}

module Network.Tangaroa.Byzantine.Handler
  ( handleEvents
  ) where

import Control.Lens
import Control.Monad hiding (mapM)
import Control.Monad.Loops
import Data.Binary
import Data.Functor
import Data.Sequence (Seq)
import Data.Set (Set)
import Data.Traversable (mapM)
import Prelude hiding (mapM)
import qualified Data.ByteString.Lazy as B
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

import Network.Tangaroa.Byzantine.Types
import Network.Tangaroa.Byzantine.Sender
import Network.Tangaroa.Byzantine.Util
import Network.Tangaroa.Byzantine.Role
import Network.Tangaroa.Byzantine.Timer

handleEvents :: (Binary nt, Binary et, Binary rt, Ord nt) => Raft nt et rt mt ()
handleEvents = forever $ do
  e <- dequeueEvent
  case e of
    ERPC rpc           -> handleRPC rpc
    ElectionTimeout s  -> handleElectionTimeout s
    HeartbeatTimeout s -> handleHeartbeatTimeout s

whenM :: Monad m => m Bool -> m () -> m ()
whenM mb ma = do
  b <- mb
  when b ma

handleRPC :: (Binary nt, Binary et, Binary rt, Ord nt) => RPC nt et rt -> Raft nt et rt mt ()
handleRPC rpc = case rpc of
  AE ae          -> whenM (verifyRPCWithKey rpc) $ handleAppendEntries ae
  AER aer        -> whenM (verifyRPCWithKey rpc) $ handleAppendEntriesResponse aer
  RV rv          -> whenM (verifyRPCWithKey rpc) $ handleRequestVote rv
  RVR rvr        -> whenM (verifyRPCWithKey rpc) $ handleRequestVoteResponse rvr
  CMD cmd        -> whenM (verifyRPCWithClientKey rpc) $ handleCommand cmd
  CMDR _         -> whenM (verifyRPCWithKey rpc) $ debug "got a command response RPC"
  DBG s          -> debug $ "got a debug RPC: " ++ s
  REVOLUTION rev -> whenM (verifyRPCWithClientKey rpc) $ handleRevolution rev

handleElectionTimeout :: (Binary nt, Binary et, Binary rt, Ord nt) => String -> Raft nt et rt mt ()
handleElectionTimeout s = do
  debug $ "election timeout: " ++ s
  r <- use role
  when (r /= Leader) $ do
    lv <- use lazyVote
    case lv of
      Just (t, c) -> do
        updateTerm t
        setVotedFor (Just c)
        lazyVote .= Nothing
        ignoreLeader .= False
        currentLeader .= Nothing
        fork_ $ sendRequestVoteResponse c True
        resetElectionTimer
      Nothing -> becomeCandidate

handleHeartbeatTimeout :: (Binary nt, Binary et, Binary rt, Ord nt) => String -> Raft nt et rt mt ()
handleHeartbeatTimeout s = do
  debug $ "heartbeat timeout: " ++ s
  r <- use role
  when (r == Leader) $ do
    fork_ sendAllAppendEntries
    resetHeartbeatTimer

checkForNewLeader :: (Binary nt, Binary et, Binary rt, Ord nt) => AppendEntries nt et -> Raft nt et rt mt ()
checkForNewLeader AppendEntries{..} = do
  ct <- use term
  cl <- use currentLeader
  if (_aeTerm == ct && cl == Just _leaderId) ||
      _aeTerm < ct ||
      Set.size _aeQuorumVotes == 0
    then return ()
    else do
      votesValid <- confirmElection _leaderId _aeTerm _aeQuorumVotes
      when votesValid $ do
        updateTerm _aeTerm
        ignoreLeader .= False
        currentLeader .= Just _leaderId

confirmElection :: (Binary nt, Binary et, Binary rt, Ord nt) => nt -> Term -> Set (RequestVoteResponse nt) -> Raft nt et rt mt Bool
confirmElection l t votes = do
  debug "confirming election of a new leader"
  qsize <- view quorumSize
  if Set.size votes >= qsize
    then allM (validateVote l t) (Set.toList votes)
    else return False

validateVote :: (Binary nt, Binary et, Binary rt, Ord nt) => nt -> Term -> RequestVoteResponse nt -> Raft nt et rt mt Bool
validateVote l t vote@RequestVoteResponse{..} = do
  sigOkay <- verifyRPCWithKey (RVR vote)
  return (sigOkay && _rvrCandidateId == l && _rvrTerm == t)

handleAppendEntries :: (Binary nt, Binary et, Binary rt, Ord nt) => AppendEntries nt et -> Raft nt et rt mt ()
handleAppendEntries ae@AppendEntries{..} = do
  debug $ "got an appendEntries RPC: prev log entry: Index " ++ show _prevLogIndex ++ " " ++ show _prevLogTerm
  checkForNewLeader ae
  cl <- use currentLeader
  ig <- use ignoreLeader
  ct <- use term
  es <- use logEntries
  let oldLastEntry = Seq.length es - 1
  case cl of
    Just l | not ig && l == _leaderId && _aeTerm == ct -> do
      resetElectionTimer
      lazyVote .= Nothing
      plmatch <- prevLogEntryMatches _prevLogIndex _prevLogTerm
      let newLastEntry = _prevLogIndex + Seq.length _aeEntries
      if _aeTerm < ct || not plmatch
        then fork_ $ sendAppendEntriesResponse _leaderId False True oldLastEntry
        else do
          appendLogEntries _prevLogIndex _aeEntries
          fork_ $ sendAppendEntriesResponse _leaderId True True newLastEntry
          nc <- use commitIndex
          when (_leaderCommit > nc) $ do
            commitIndex .= min _leaderCommit newLastEntry
            applyLogEntries
    _ | not ig && _aeTerm >= ct -> do
      debug "sending unconvinced response"
      fork_ $ sendAppendEntriesResponse _leaderId False False oldLastEntry
    _ -> return ()

prevLogEntryMatches :: LogIndex -> Term -> Raft nt et rt mt Bool
prevLogEntryMatches pli plt = do
  es <- use logEntries
  case seqIndex es pli of
    -- if we don't have the entry, only return true if pli is startIndex
    Nothing    -> return (pli == startIndex)
    -- if we do have the entry, return true if the terms match
    Just (t,_) -> return (t == plt)

-- TODO: check this
appendLogEntries :: LogIndex -> Seq (Term, Command nt et) -> Raft nt et rt mt ()
appendLogEntries pli es =
  logEntries %= (Seq.>< es) . Seq.take (pli + 1)

handleAppendEntriesResponse :: (Binary nt, Binary et, Binary rt, Ord nt) => AppendEntriesResponse nt -> Raft nt et rt mt ()
handleAppendEntriesResponse AppendEntriesResponse{..} = do
  debug "got an appendEntriesResponse RPC"
  r <- use role
  ct <- use term
  when (r == Leader) $ do
    when (not _aerConvinced && _aerTerm <= ct) $ -- implies not _aerSuccess
      lConvinced %= Set.delete _aerNodeId
    when (_aerTerm == ct) $ do
      when (_aerConvinced && not _aerSuccess) $
        lNextIndex %= Map.adjust (subtract 1) _aerNodeId
      when (_aerConvinced && _aerSuccess) $ do
        lMatchIndex.at _aerNodeId .= Just _aerIndex
        lNextIndex .at _aerNodeId .= Just (_aerIndex + 1)
        lConvinced %= Set.insert _aerNodeId
        leaderDoCommit
    when (not _aerConvinced || not _aerSuccess) $
      fork_ $ sendAppendEntries _aerNodeId

applyCommand :: Ord nt => Command nt et -> Raft nt et rt mt (nt, CommandResponse nt rt)
applyCommand cmd@Command{..} = do
  apply <- view (rs.applyLogEntry)
  result <- apply _cmdEntry
  replayMap %= Map.insert (_cmdClientId, _cmdSig) (Just result)
  ((,) _cmdClientId) <$> makeCommandResponse cmd result

makeCommandResponse :: Command nt et -> rt -> Raft nt et rt mt (CommandResponse nt rt)
makeCommandResponse Command{..} result = do
  nid <- view (cfg.nodeId)
  mlid <- use currentLeader
  return $ CommandResponse
             result
             (maybe nid id mlid)
             nid
             _cmdRequestId
             B.empty

leaderDoCommit :: (Binary nt, Binary et, Binary rt, Ord nt) => Raft nt et rt mt ()
leaderDoCommit = do
  commitUpdate <- leaderUpdateCommitIndex
  when commitUpdate applyLogEntries

-- apply the un-applied log entries up through commitIndex
-- and send results to the client if you are the leader
-- TODO: have this done on a separate thread via event passing
applyLogEntries :: (Binary nt, Binary et, Binary rt, Ord nt) => Raft nt et rt mt ()
applyLogEntries = do
  la <- use lastApplied
  ci <- use commitIndex
  le <- use logEntries
  let leToApply = fmap (^. _2) . Seq.drop (la + 1) . Seq.take (ci + 1) $ le
  results <- mapM applyCommand leToApply
  r <- use role
  when (r == Leader) $ fork_ $ sendResults results
  lastApplied .= ci


-- called only as leader
-- checks to see what the largest N where a majority of
-- the lMatchIndex set is >= N
leaderUpdateCommitIndex :: Ord nt => Raft nt et rt mt Bool
leaderUpdateCommitIndex = do
  ci <- use commitIndex
  lmi <- use lMatchIndex
  qsize <- view quorumSize
  ct <- use term
  es <- use logEntries

  -- get all indices in the log past commitIndex and take the ones where the entry's
  -- term is equal to the current term
  let ctinds = filter (\i -> maybe False ((== ct) . fst) (seqIndex es i))
                      [(ci + 1)..(Seq.length es - 1)]

  -- get the prefix of these indices where a quorum of nodes have matching
  -- indices for that entry. lMatchIndex doesn't include the leader, so add
  -- one to the size
  let qcinds = takeWhile (\i -> 1 + Map.size (Map.filter (>= i) lmi) >= qsize) ctinds

  case qcinds of
    [] -> return False
    _  -> do
      commitIndex .= last qcinds
      debug $ "commit index is now: " ++ show (last qcinds)
      return True

handleRequestVote :: (Binary nt, Binary et, Binary rt, Eq nt) => RequestVote nt -> Raft nt et rt mt ()
handleRequestVote RequestVote{..} = do
  debug $ "got a requestVote RPC for " ++ show _rvTerm
  mvote <- use votedFor
  es <- use logEntries
  ct <- use term
  case mvote of
    _      | _rvTerm < ct -> do
      -- this is an old candidate
      debug "this is for an old term"
      fork_ $ sendRequestVoteResponse _rvCandidateId False

    Just c | c == _rvCandidateId && _rvTerm == ct -> do
      -- already voted for this candidate in this term
      debug "already voted for this candidate"
      fork_ $ sendRequestVoteResponse _rvCandidateId True

    Just _ | _rvTerm == ct -> do
      -- already voted for a different candidate in this term
      debug "already voted for a different candidate"
      fork_ $ sendRequestVoteResponse _rvCandidateId False

    _ -> if (_lastLogTerm, _lastLogIndex) >= lastLogInfo es
      -- we have no recorded vote, or this request is for a higher term
      -- (we don't externalize votes without updating our own term, so we
      -- haven't voted in the higher term before)
      -- lazily vote for the candidate if its log is at least as
      -- up to date as ours, use the Ord instance of (Term, Index) to prefer
      -- higher terms, and then higher last indices for equal terms
      then do
        lv <- use lazyVote
        case lv of
          Just (t, _) | t >= _rvTerm ->
            debug "would vote lazily, but already voted lazily for candidate in same or higher term"
          Just _ -> do
            debug "replacing lazy vote"
            lazyVote .= Just (_rvTerm, _rvCandidateId)
          Nothing -> do
            debug "haven't voted, (lazily) voting for this candidate"
            lazyVote .= Just (_rvTerm, _rvCandidateId)
      else do
        debug "haven't voted, but my log is better than this candidate's"
        fork_ $ sendRequestVoteResponse _rvCandidateId False

handleRequestVoteResponse :: (Binary nt, Binary et, Binary rt, Ord nt) => RequestVoteResponse nt -> Raft nt et rt mt ()
handleRequestVoteResponse rvr@RequestVoteResponse{..} = do
  debug $ "got a requestVoteResponse RPC for " ++ show _rvrTerm ++ ": " ++ show _voteGranted
  r <- use role
  ct <- use term
  when (r == Candidate && ct == _rvrTerm) $
    if _voteGranted
      then do
        cYesVotes %= Set.insert rvr
        checkElection
      else
        cPotentialVotes %= Set.delete _rvrNodeId

handleCommand :: (Binary nt, Binary et, Binary rt, Ord nt) => Command nt et -> Raft nt et rt mt ()
handleCommand cmd@Command{..} = do
  debug "got a command RPC"
  r <- use role
  ct <- use term
  mlid <- use currentLeader
  replays <- use replayMap
  case (Map.lookup (_cmdClientId, _cmdSig) replays, r, mlid) of
    (Just (Just result), _, _) -> do
      cmdr <- makeCommandResponse cmd result
      sendSignedRPC _cmdClientId $ CMDR cmdr
      -- we have already seen this request, so send the result to the client
    (_, Leader, _) -> do
      -- we're the leader, so append this to our log with the current term
      -- and propagate it to replicas
      logEntries %= (Seq.|> (ct, cmd))
      fork_ sendAllAppendEntries
      leaderDoCommit
    (_, _, Just lid) ->
      -- we're not the leader, but we know who the leader is, so forward this
      -- command (don't sign it ourselves, as it comes from the client)
      fork_ $ sendRPC lid $ CMD cmd
    (_, _, Nothing) ->
      -- we're not the leader, and we don't know who the leader is, so can't do
      -- anything
      return ()

handleRevolution :: Ord nt => Revolution nt -> Raft nt et rt mt ()
handleRevolution Revolution{..} = do
  cl <- use currentLeader
  whenM (Map.notMember (_revClientId, _revSig) <$> use replayMap) $
    case cl of
      Just l | l == _revLeaderId -> do
        replayMap %= Map.insert (_revClientId, _revSig) Nothing
        ignoreLeader .= True
      _ -> return ()
