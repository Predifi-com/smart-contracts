// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PredifiPool} from "../src/PredifiPool.sol";

contract MockPoolAsset is ERC20 {
    constructor() ERC20("Mock Pool Asset", "mUSDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PredifiPoolTest is Test {
    MockPoolAsset asset;
    PredifiPool pool;

    address admin = address(0xA11CE);
    address user = address(0xCAFE);
    address ledger = address(0x1ED9E);
    address recipient = address(0xBEEF);

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount, address indexed authorizedBy);

    function setUp() public {
        asset = new MockPoolAsset();
        PredifiPool implementation = new PredifiPool();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(PredifiPool.initialize, (address(asset), admin))
        );
        pool = PredifiPool(payable(address(proxy)));

        vm.prank(admin);
        pool.grantLedgerRole(ledger);

        asset.mint(user, 1_000e6);
        vm.prank(user);
        asset.approve(address(pool), type(uint256).max);
    }

    function testDepositEmitsEventAndIncreasesPoolBalance() public {
        vm.expectEmit(true, false, false, true);
        emit Deposited(user, 500e6);

        vm.prank(user);
        pool.deposit(500e6);

        assertEq(asset.balanceOf(address(pool)), 500e6);
        assertEq(pool.totalBalance(), 500e6);
    }

    function testLedgerWithdrawEmitsEventAndTransfersAsset() public {
        vm.prank(user);
        pool.deposit(500e6);

        vm.expectEmit(true, false, true, true);
        emit Withdrawn(recipient, 125e6, ledger);

        vm.prank(ledger);
        pool.withdraw(recipient, 125e6);

        assertEq(asset.balanceOf(recipient), 125e6);
        assertEq(asset.balanceOf(address(pool)), 375e6);
    }

    function testNonLedgerCannotWithdraw() public {
        vm.prank(user);
        pool.deposit(500e6);

        vm.prank(user);
        vm.expectRevert();
        pool.withdraw(recipient, 1e6);
    }

    function testPauseBlocksDepositAndWithdraw() public {
        vm.prank(admin);
        pool.pause();

        vm.prank(user);
        vm.expectRevert();
        pool.deposit(1e6);

        vm.prank(ledger);
        vm.expectRevert();
        pool.withdraw(recipient, 1e6);
    }
}
