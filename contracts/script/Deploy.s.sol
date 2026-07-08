// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/GenesisVouch.sol";

/// @notice Deploy GenesisVouch to Ritual. Pure vouching game — no member wallets to seed.
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url https://rpc.ritualfoundation.org \
///     --broadcast --private-key $PRIVATE_KEY
///
/// Env:
///   PLATFORM_WALLET   - address that receives the platform fee (defaults to deployer)
///   MAX_MEMBER_ID     - roster size (default 988)
///   PLATFORM_FEE_BPS  - platform fee in basis points (default 2500 = 25%, cap 3000)
///   ROUND_DURATION_MS - round length in Ritual's block.timestamp units (MILLISECONDS).
///                       Default 604_800_000 = 7 days. Ritual clocks in ms, so do NOT pass
///                       604_800 (that is ~10 minutes on-chain).
contract Deploy is Script {
    function run() external returns (GenesisVouch gv) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address platform = vm.envOr("PLATFORM_WALLET", deployer);
        uint16 maxId = uint16(vm.envOr("MAX_MEMBER_ID", uint256(988)));
        uint256 feeBps = vm.envOr("PLATFORM_FEE_BPS", uint256(2500));
        uint256 roundMs = vm.envOr("ROUND_DURATION_MS", uint256(604_800_000)); // 7 days in ms

        vm.startBroadcast(pk);
        gv = new GenesisVouch(platform, maxId, feeBps, roundMs);
        vm.stopBroadcast();

        console2.log("GenesisVouch deployed:", address(gv));
        console2.log("platformWallet:", platform);
        console2.log("maxMemberId:", maxId);
        console2.log("platformFeeBps:", feeBps);
        console2.log("roundDuration(ms):", roundMs);
        console2.log("Paste the address into frontend/app.js CONTRACT_ADDRESS.");
    }
}
