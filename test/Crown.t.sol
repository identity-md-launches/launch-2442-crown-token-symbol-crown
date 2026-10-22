// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Crown} from "../src/Crown.sol";

contract CrownTest is Test {
    Crown token;
    address alice;
    address bob;

    function setUp() public {
        token = new Crown();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_metadataAndOneTimeSupply() public view {
        assertEq(token.name(), "Crown");
        assertEq(token.symbol(), "CROWN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }

    function test_transfersAndAllowanceHaveNoTax() public {
        assertTrue(token.transfer(alice, 100 ether));
        vm.prank(alice);
        token.approve(bob, 20 ether);
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 20 ether));
        assertEq(token.balanceOf(alice), 80 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.totalSupply(), token.SUPPLY());
        vm.prank(bob);
        vm.expectRevert();
        token.transferFrom(alice, bob, 1);
    }

    function test_rejectsZeroRecipientAndInsufficientBalance() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    function test_noPrivilegedEntryPointsEvenForDeployer() public {
        bytes4[8] memory selectors = [
            bytes4(keccak256("mint(address,uint256)")),
            bytes4(keccak256("owner()")),
            bytes4(keccak256("pause()")),
            bytes4(keccak256("upgradeTo(address)")),
            bytes4(keccak256("setMinter(address)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("blacklist(address)")),
            bytes4(keccak256("burnFrom(address,uint256)"))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSelector(selectors[i], alice, 1 ether));
            assertFalse(ok);
        }
        assertEq(token.balanceOf(address(this)), token.SUPPLY());
    }

    function testFuzz_transferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.SUPPLY());
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(alice) + token.balanceOf(address(this)), token.SUPPLY());
    }
}
