// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Stand-in for a TapeOut transistor contract (ERC-1155, id 0 = NAND, id 1 = LATCH).
contract MockTransistors is ERC1155 {
    uint256 public constant mintPrice = 0.000066 ether;
    uint256 public constant PROTOCOL_FEE = 0.00066 ether;
    uint256 public proceeds;

    constructor() ERC1155("") {}

    /// @dev Paid mint with the real TapeOut signature: price * amount + protocol fee, minted to caller.
    function mint(uint256 id, uint256 amount) external payable {
        require(msg.value == mintPrice * amount + PROTOCOL_FEE, "bad value");
        proceeds += mintPrice * amount;
        _mint(msg.sender, id, amount, "");
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external {
        _burn(from, id, amount);
    }
}

/// @notice Stand-in for a TapeOut processor that interprets real netlist bytes exactly like the
/// on-chain eval (combinational only): signals 0/1 = const, 2.. = inputs, then one per gate;
/// outputs = last nOut signals; inputs/outputs packed little-endian.
contract MockProcessor is ERC721 {
    struct Circuit {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint32 gateCount;
    }

    MockTransistors public immutable transistors;
    mapping(uint256 => Circuit) internal _circuits;
    uint256 public nextId = 1;

    constructor(MockTransistors t) ERC721("Mock Processor", "CPU") {
        transistors = t;
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external returns (uint256 id) {
        uint32 gates = uint32(nl.length / 7);
        transistors.burn(msg.sender, 0, gates);
        id = nextId++;
        _circuits[id] = Circuit(nl, nIn, nOut, gates);
        _mint(msg.sender, id);
    }

    /// @dev Test hook: simulates TapeOut upgrading the processor so a circuit changes behaviour.
    function tamper(uint256 id, bytes calldata nl) external {
        _circuits[id].netlist = nl;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Circuit storage c = _circuits[id];
        return (c.nIn, c.nOut, 0, c.gateCount);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return _circuits[id].netlist;
    }

    function eval(uint256 id, bytes calldata input) external view returns (bytes memory out) {
        Circuit storage c = _circuits[id];
        require(c.nIn != 0, "no circuit");
        bytes memory nl = c.netlist;
        uint256 nIn = c.nIn;
        uint256 total = 2 + nIn + nl.length / 7;
        bytes memory v = new bytes(total);
        v[1] = 0x01;
        for (uint256 i = 0; i < nIn; i++) {
            v[2 + i] = bytes1((uint8(input[i >> 3]) >> (i & 7)) & 1);
        }
        uint256 sig = 2 + nIn;
        for (uint256 p = 0; p < nl.length; p += 7) {
            require(nl[p] == 0x00, "only NAND");
            uint256 a = (uint256(uint8(nl[p + 1])) << 16) | (uint256(uint8(nl[p + 2])) << 8) | uint8(nl[p + 3]);
            uint256 b = (uint256(uint8(nl[p + 4])) << 16) | (uint256(uint8(nl[p + 5])) << 8) | uint8(nl[p + 6]);
            v[sig++] = bytes1(1 - (uint8(v[a]) & uint8(v[b])));
        }
        uint256 nOut = c.nOut;
        out = new bytes((nOut + 7) / 8);
        for (uint256 i = 0; i < nOut; i++) {
            if (v[total - nOut + i] != 0) out[i >> 3] = bytes1(uint8(out[i >> 3]) | uint8(1 << (i & 7)));
        }
    }
}

contract MockWOKB is ERC20 {
    constructor() ERC20("Wrapped OKB", "WOKB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stand-in for TapeOut's processor beacon; `upgrade` simulates TapeOut shipping new code.
contract MockBeacon {
    address public implementation = address(0x1111);

    function upgrade(address impl) external {
        implementation = impl;
    }
}

contract MockFactory {
    function protocolFee() external pure returns (uint256) {
        return 0.00066 ether;
    }
}
