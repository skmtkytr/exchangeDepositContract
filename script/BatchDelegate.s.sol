// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @title BatchDelegate - 1TXで複数EOAをEIP-7702 delegateする (Sepolia)
contract BatchDelegate is Script {
    function run() external {
        address delegateTarget = vm.envAddress("DELEGATE_TARGET");

        // EOAのキーはテスト用なので環境変数でOK
        // sender（ガス支払い）は --account で keystore から読む
        uint256 keyA = vm.envUint("EOA_KEY_A");
        uint256 keyB = vm.envUint("EOA_KEY_B");
        uint256 keyC = vm.envUint("EOA_KEY_C");

        address eoaA = vm.addr(keyA);
        address eoaB = vm.addr(keyB);
        address eoaC = vm.addr(keyC);

        console.log("Delegate target:", delegateTarget);
        console.log("EOA_A:", eoaA);
        console.log("EOA_B:", eoaB);
        console.log("EOA_C:", eoaC);

        // 3つのEOAのauthorizationを署名 → 次のTXに添付
        vm.signAndAttachDelegation(delegateTarget, keyA);
        vm.signAndAttachDelegation(delegateTarget, keyB);
        vm.signAndAttachDelegation(delegateTarget, keyC);

        // senderでブロードキャスト（1TX） - --account で署名
        vm.startBroadcast();
        // 空のcallでdelegation authorizationだけ処理させる
        address(0).call("");
        vm.stopBroadcast();

        // 確認
        console.log("--- After delegation ---");
        console.log("EOA_A code size:", eoaA.code.length);
        console.log("EOA_B code size:", eoaB.code.length);
        console.log("EOA_C code size:", eoaC.code.length);
    }
}
