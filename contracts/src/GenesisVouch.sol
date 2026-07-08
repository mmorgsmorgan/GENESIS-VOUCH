// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GenesisVouch
/// @notice Weekly popularity vouching game over the Ritual "Genesis 1000" roster.
///         Backers stake native RITUAL on the community member they believe is most known.
///         Each round the most-vouched member wins; the wallets that vouched for the winner
///         split the whole pool. The Genesis members are the *subjects* being vouched on —
///         they are not participants and receive nothing, so no member wallets are needed.
///
///         Settlement of the WINNER's own pool P:
///           - platformFeeBps (default 25%) -> the platform wallet
///           - the remainder                -> the backer reward pot
///         All stake on every OTHER member is seized 100% into the backer reward pot.
///         The winner's backers claim pro-rata to their stake on the winner.
///
///         Members are addressed by uint16 memberId (1..maxMemberId). Names/PFPs live
///         off-chain in members.json; the contract is name-agnostic so the roster can grow.
contract GenesisVouch {
    // ------------------------------------------------------------------ //
    //  Errors
    // ------------------------------------------------------------------ //
    error NotOwner();
    error RoundOver();
    error RoundNotOver();
    error AlreadySettled();
    error NotSettled();
    error BadMember();
    error BelowMinVouch();
    error NothingToClaim();
    error AlreadyClaimed();
    error TransferFailed();
    error ZeroAddress();
    error FeeTooHigh();
    error BadDuration();
    error Reentrancy();

    // ------------------------------------------------------------------ //
    //  Constants / config
    // ------------------------------------------------------------------ //
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant MAX_FEE_BPS = 3_000; // platform fee hard cap 30%
    uint256 public constant MIN_VOUCH = 0.001 ether; // dust floor (native RITUAL, 18 dp)

    /// @notice Round length in the CHAIN's own block.timestamp units. This must match the
    ///         chain's clock resolution: Ritual reports block.timestamp in MILLISECONDS, so a
    ///         7-day round is 604_800_000 here — NOT the Solidity `7 days` (604_800) literal,
    ///         which would settle in ~10 minutes on Ritual. Set once at deploy; forge tests that
    ///         drive `vm.warp` in seconds pass 604_800 instead.
    uint256 public immutable roundDuration;

    uint256 public platformFeeBps; // portion of the winner's pool that goes to the platform

    // ------------------------------------------------------------------ //
    //  Round state
    // ------------------------------------------------------------------ //
    struct Round {
        uint256 totalStaked; // sum of all stake this round
        uint256 leaderTotal; // highest single-member total (running max)
        uint256 winnerPool; // snapshot of leaderTotal at settlement (== P)
        uint256 backerPot; // reward pot for the winner's backers (set at settlement)
        uint16 leaderId; // current running leader (winner at settlement)
        uint16 winnerId; // snapshot of leaderId at settlement
        bool settled;
    }

    uint256 public roundId; // active round
    uint256 public roundStart; // active round start timestamp

    mapping(uint256 => Round) public rounds;
    // round => memberId => total staked on that member
    mapping(uint256 => mapping(uint16 => uint256)) public memberTotal;
    // round => memberId => backer => stake
    mapping(uint256 => mapping(uint16 => mapping(address => uint256))) public stakeOf;
    // round => backer => claimed?
    mapping(uint256 => mapping(address => bool)) public backerClaimed;

    // per-round list of members that received stake (for cheap frontend reads)
    mapping(uint256 => uint16[]) private _active;
    mapping(uint256 => mapping(uint16 => bool)) private _seen;

    // ------------------------------------------------------------------ //
    //  Admin
    // ------------------------------------------------------------------ //
    address public owner;
    address public platformWallet;
    uint16 public maxMemberId;

    // ------------------------------------------------------------------ //
    //  Reentrancy guard (minimal, no external dep)
    // ------------------------------------------------------------------ //
    uint256 private _lock = 1;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------ //
    //  Events
    // ------------------------------------------------------------------ //
    event Vouched(uint256 indexed round, uint16 indexed memberId, address indexed backer, uint256 amount, uint256 newMemberTotal);
    event Settled(uint256 indexed round, uint16 indexed winnerId, uint256 winnerPool, uint256 platformShare, uint256 backerPot, uint256 losersSeized);
    event RewardClaimed(uint256 indexed round, address indexed backer, uint256 amount);
    event PlatformWalletSet(address wallet);
    event PlatformFeeSet(uint256 bps);
    event MaxMemberIdSet(uint16 maxMemberId);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------------------------------------------ //
    //  Constructor
    // ------------------------------------------------------------------ //
    constructor(address _platformWallet, uint16 _maxMemberId, uint256 _platformFeeBps, uint256 _roundDuration) {
        if (_platformWallet == address(0)) revert ZeroAddress();
        if (_platformFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (_roundDuration == 0) revert BadDuration();
        owner = msg.sender;
        platformWallet = _platformWallet;
        maxMemberId = _maxMemberId;
        platformFeeBps = _platformFeeBps;
        roundDuration = _roundDuration;
        roundId = 1;
        roundStart = block.timestamp;
        emit PlatformWalletSet(_platformWallet);
        emit PlatformFeeSet(_platformFeeBps);
        emit MaxMemberIdSet(_maxMemberId);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ------------------------------------------------------------------ //
    //  Core: vouch
    // ------------------------------------------------------------------ //
    /// @notice Stake native RITUAL on a member during the active round.
    function vouch(uint16 memberId) external payable {
        if (block.timestamp >= roundStart + roundDuration) revert RoundOver();
        if (memberId == 0 || memberId > maxMemberId) revert BadMember();
        if (msg.value < MIN_VOUCH) revert BelowMinVouch();

        uint256 r = roundId;
        Round storage rd = rounds[r];

        uint256 newTotal = memberTotal[r][memberId] + msg.value;
        memberTotal[r][memberId] = newTotal;
        stakeOf[r][memberId][msg.sender] += msg.value;
        rd.totalStaked += msg.value;

        if (!_seen[r][memberId]) {
            _seen[r][memberId] = true;
            _active[r].push(memberId);
        }

        // running leader — strict > keeps first-to-reach on ties (deterministic, O(1))
        if (newTotal > rd.leaderTotal) {
            rd.leaderTotal = newTotal;
            rd.leaderId = memberId;
        }

        emit Vouched(r, memberId, msg.sender, msg.value, newTotal);
    }

    // ------------------------------------------------------------------ //
    //  Core: settle (permissionless, after the round ends)
    // ------------------------------------------------------------------ //
    function settle() external nonReentrant {
        uint256 r = roundId;
        Round storage rd = rounds[r];
        if (block.timestamp < roundStart + roundDuration) revert RoundNotOver();
        if (rd.settled) revert AlreadySettled();

        rd.settled = true;

        // No stake at all -> nothing to pay, just roll to the next round.
        if (rd.totalStaked == 0) {
            _advanceRound();
            emit Settled(r, 0, 0, 0, 0, 0);
            return;
        }

        uint16 w = rd.leaderId;
        uint256 p = rd.leaderTotal; // winner's own pool
        uint256 losers = rd.totalStaked - p; // everyone else, seized 100%

        uint256 platformShare = (p * platformFeeBps) / BPS_DENOM;
        // backer pot = remainder of the winner's pool (75% by default) + all losing stakes
        uint256 backerPot = p - platformShare + losers;

        rd.winnerId = w;
        rd.winnerPool = p;
        rd.backerPot = backerPot;

        _advanceRound();

        // Interactions last.
        if (platformShare > 0) _send(platformWallet, platformShare);

        emit Settled(r, w, p, platformShare, backerPot, losers);
    }

    function _advanceRound() private {
        roundId += 1;
        roundStart = block.timestamp;
    }

    // ------------------------------------------------------------------ //
    //  Claims (pull-based)
    // ------------------------------------------------------------------ //
    /// @notice Winner's backers claim their pro-rata share of the backer pot.
    function claimBackerReward(uint256 r) external nonReentrant {
        Round storage rd = rounds[r];
        if (!rd.settled) revert NotSettled();
        if (backerClaimed[r][msg.sender]) revert AlreadyClaimed();

        uint256 stake = stakeOf[r][rd.winnerId][msg.sender];
        if (stake == 0 || rd.winnerPool == 0) revert NothingToClaim();

        uint256 reward = (stake * rd.backerPot) / rd.winnerPool;
        if (reward == 0) revert NothingToClaim();

        backerClaimed[r][msg.sender] = true;
        _send(msg.sender, reward);
        emit RewardClaimed(r, msg.sender, reward);
    }

    // ------------------------------------------------------------------ //
    //  Admin
    // ------------------------------------------------------------------ //
    function setPlatformWallet(address w) external onlyOwner {
        if (w == address(0)) revert ZeroAddress();
        platformWallet = w;
        emit PlatformWalletSet(w);
    }

    function setPlatformFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        platformFeeBps = bps;
        emit PlatformFeeSet(bps);
    }

    function setMaxMemberId(uint16 m) external onlyOwner {
        maxMemberId = m;
        emit MaxMemberIdSet(m);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    // ------------------------------------------------------------------ //
    //  Views (frontend)
    // ------------------------------------------------------------------ //
    /// @notice All members with stake this round + their totals (single cheap read).
    function getActiveTotals()
        external
        view
        returns (uint16[] memory ids, uint256[] memory amounts)
    {
        return getActiveTotalsAt(roundId);
    }

    function getActiveTotalsAt(uint256 r)
        public
        view
        returns (uint16[] memory ids, uint256[] memory amounts)
    {
        uint16[] storage a = _active[r];
        uint256 n = a.length;
        ids = new uint16[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = a[i];
            amounts[i] = memberTotal[r][a[i]];
        }
    }

    function getRound(uint256 r) external view returns (Round memory) {
        return rounds[r];
    }

    /// @notice Live view of the active round header for the hero (timer/pot/leader).
    function currentRound()
        external
        view
        returns (uint256 id, uint256 startsAt, uint256 endsAt, uint256 totalStaked, uint16 leaderId, uint256 leaderTotal)
    {
        Round storage rd = rounds[roundId];
        return (roundId, roundStart, roundStart + roundDuration, rd.totalStaked, rd.leaderId, rd.leaderTotal);
    }

    function myStake(uint256 r, uint16 memberId, address who) external view returns (uint256) {
        return stakeOf[r][memberId][who];
    }

    /// @notice What `who` could claim as a backer of round r's winner (0 if not settled/none).
    function pendingBackerReward(uint256 r, address who) external view returns (uint256) {
        Round storage rd = rounds[r];
        if (!rd.settled || rd.winnerPool == 0 || backerClaimed[r][who]) return 0;
        uint256 stake = stakeOf[r][rd.winnerId][who];
        if (stake == 0) return 0;
        return (stake * rd.backerPot) / rd.winnerPool;
    }

    // ------------------------------------------------------------------ //
    //  Internal
    // ------------------------------------------------------------------ //
    function _send(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {
        revert("use vouch()");
    }
}
