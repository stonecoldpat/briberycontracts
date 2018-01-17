pragma solidity ^0.4.10;

// parse a raw bitcoin transaction byte array
// from here https://github.com/rainbreak/solidity-btc-parser/blob/master/src/btc_tx.sol
// and flip code is from here https://github.com/tjade273/BTCRelay-tools
contract BTC {

    function flip32(bytes32 data) constant returns (bytes32 out){
      for(uint i; i<32; i++){
          out = out | bytes32(uint(data[i]) * (0x100**i));
      }
    }


    // Convert a variable integer into something useful and return it and
    // the index to after it.
    function parseVarInt(bytes txBytes, uint pos) returns (uint, uint) {
        // the first byte tells us how big the integer is
        var ibit = uint8(txBytes[pos]);
        pos += 1;  // skip ibit

        if (ibit < 0xfd) {
            return (ibit, pos);
        } else if (ibit == 0xfd) {
            return (getBytesLE(txBytes, pos, 16), pos + 2);
        } else if (ibit == 0xfe) {
            return (getBytesLE(txBytes, pos, 32), pos + 4);
        } else if (ibit == 0xff) {
            return (getBytesLE(txBytes, pos, 64), pos + 8);
        }
    }

    // convert little endian bytes to uint
    function getBytesLE(bytes data, uint pos, uint bits) returns (uint) {
        if (bits == 8) {
            return uint8(data[pos]);
        } else if (bits == 16) {
            return uint16(data[pos])
                 + uint16(data[pos + 1]) * 2 ** 8;
        } else if (bits == 32) {
            return uint32(data[pos])
                 + uint32(data[pos + 1]) * 2 ** 8
                 + uint32(data[pos + 2]) * 2 ** 16
                 + uint32(data[pos + 3]) * 2 ** 24;
        } else if (bits == 64) {
            return uint64(data[pos])
                 + uint64(data[pos + 1]) * 2 ** 8
                 + uint64(data[pos + 2]) * 2 ** 16
                 + uint64(data[pos + 3]) * 2 ** 24
                 + uint64(data[pos + 4]) * 2 ** 32
                 + uint64(data[pos + 5]) * 2 ** 40
                 + uint64(data[pos + 6]) * 2 ** 48
                 + uint64(data[pos + 7]) * 2 ** 56;
        }
    }
    // scan the full transaction bytes and return the first two output
    // values (in satoshis) and addresses (in binary)
    function getFirstTwoOutputs(bytes txBytes)
             returns (uint, bytes20, uint, bytes20)
    {
        uint pos;
        uint[] memory input_script_lens = new uint[](2);
        uint[] memory output_script_lens = new uint[](2);
        uint[] memory script_starts = new uint[](2);
        uint[] memory output_values = new uint[](2);
        bytes20[] memory output_addresses = new bytes20[](2);

        pos = 4;  // skip version

        (input_script_lens, pos) = scanInputs(txBytes, pos, 0);

        (output_values, script_starts, output_script_lens, pos) = scanOutputs(txBytes, pos, 2);

        for (uint i = 0; i < 2; i++) {
            var pkhash = parseOutputScript(txBytes, script_starts[i], output_script_lens[i]);
            output_addresses[i] = pkhash;
        }

        return (output_values[0], output_addresses[0],
                output_values[1], output_addresses[1]);
    }

    // Fetch Ethereum account from Coinbase tx
    // DISCLAIMER: I have not tested whether ethereum account derived is correct or not.
    // but it does follow the process outlined in the yellow paper.
    function getEthereumAccountFromPubKey(bytes txBytes)
             returns (address)
    {
        uint pos;
        uint[] memory input_script_lens = new uint[](2);
        uint[] memory output_script_lens = new uint[](2);
        uint[] memory script_starts = new uint[](2);
        uint[] memory output_values = new uint[](2);

        pos = 4;  // skip version

        (input_script_lens, pos) = scanInputs(txBytes, pos, 0);

        (output_values, script_starts, output_script_lens, pos) = scanOutputs(txBytes, pos, 1);

        if(isP2PK(txBytes, script_starts[0])) {
          // Grab bytes between 2 and 65
          byte[] memory pubkey = new byte[](64);
          for(uint i=2; i<=65; i++) {
            pubkey[i-2] = txBytes[script_starts[0] + i]; // Push 65 bytes here...
          }

          // Hash public key using keccak256
          bytes32 h = sha3(pubkey);

          bytes32 mask20 = 0xffffffffffffffffffffffffffffffffffffffff000000000000000000000000;
          address addr = address(bytes20((h<<(12))&mask20));

          // Last 20 bytes = Ethereum account.
          return addr;
        }

        throw;
    }

    // scan the full transaction bytes and return the first output
    // values (in satoshis) and addresses (in binary)
    function getFirstOutput(bytes txBytes)
             returns (uint, bytes20)
    {
        uint pos;
        uint[] memory input_script_lens = new uint[](2);
        uint[] memory output_script_lens = new uint[](2);
        uint[] memory script_starts = new uint[](2);
        uint[] memory output_values = new uint[](2);
        bytes20[] memory output_addresses = new bytes20[](2);

        pos = 4;  // skip version

        (input_script_lens, pos) = scanInputs(txBytes, pos, 0);

        (output_values, script_starts, output_script_lens, pos) = scanOutputs(txBytes, pos, 1);

        var pkhash = parseOutputScript(txBytes, script_starts[0], output_script_lens[0]);
        output_addresses[0] = pkhash;

        return (output_values[0], output_addresses[0]);
    }


    function checkValueSent(bytes txBytes, bytes20 btcAddress, uint value)
             returns (bool)
    {
        uint pos = 4;  // skip version
        uint[] memory empty;
        (empty, pos) = scanInputs(txBytes, pos, 0);  // find end of inputs

        // scan *all* the outputs and find where they are
        var (output_values, script_starts, output_script_lens,empty2) = scanOutputs(txBytes, pos, 0);

        empty2 = empty2;
        // look at each output and check whether it at least value to btcAddress
        for (uint i = 0; i < output_values.length; i++) {
            var pkhash = parseOutputScript(txBytes, script_starts[i], output_script_lens[i]);
            if (pkhash == btcAddress && output_values[i] >= value) {
                return true;
            }
        }
    }

    function scanInputs(bytes txBytes, uint pos, uint stop)
             returns (uint[], uint)
    {
        uint n_inputs;
        uint halt;
        uint script_len;

        (n_inputs, pos) = parseVarInt(txBytes, pos);

        if (stop == 0 || stop > n_inputs) {
            halt = n_inputs;
        } else {
            halt = stop;
        }

        uint[] memory script_lens = new uint[](halt);

        for (var i = 0; i < halt; i++) {
            pos += 36;  // skip outpoint
            (script_len, pos) = parseVarInt(txBytes, pos);
            script_lens[i] = script_len;
            pos += script_len + 4;  //
        }

        return (script_lens, pos);
    }


    function scanOutputs(bytes txBytes, uint pos, uint stop)
             returns (uint[], uint[], uint[], uint)
    {
        uint n_outputs;
        uint halt;
        uint script_len;

        (n_outputs, pos) = parseVarInt(txBytes, pos);

        if (stop == 0 || stop > n_outputs) {
            halt = n_outputs;
        } else {
            halt = stop;
        }

        uint[] memory script_starts = new uint[](halt);
        uint[] memory script_lens = new uint[](halt);
        uint[] memory output_values = new uint[](halt);

        for (var i = 0; i < halt; i++) {
            output_values[i] = getBytesLE(txBytes, pos, 64);
            pos += 8;

            (script_len, pos) = parseVarInt(txBytes, pos);
            script_starts[i] = pos;
            script_lens[i] = script_len;
            pos += script_len;
        }

        return (output_values, script_starts, script_lens, pos);
    }

    // https://bitcoin.stackexchange.com/questions/32639/why-does-the-default-miner-implementation-use-pay-to-pubkey/32642 helped alot
    function isP2PK(bytes txBytes, uint pos) returns (bool) {
        return (txBytes[pos] == 0x41)   // Represents pushing 65 bytes to the stack
            && (txBytes[pos+1] == 0x04)
            && (txBytes[pos + 66] == 0xac);  // OPCHECKSIG
    }

    function sliceBytes20(bytes data, uint start) returns (bytes20) {
        uint160 slice = 0;
        for (uint160 i = 0; i < 20; i++) {
            slice += uint160(data[i + start]) << (8 * (19 - i));
        }
        return bytes20(slice);
    }


    function isP2PKH(bytes txBytes, uint pos, uint script_len) returns (bool) {
        return (script_len == 25)           // 20 byte pubkeyhash + 5 bytes of script
            && (txBytes[pos] == 0x76)       // OPDUP
            && (txBytes[pos + 1] == 0xa9)   // OPHASH160
            && (txBytes[pos + 2] == 0x14)   // bytes to push
            && (txBytes[pos + 23] == 0x88)  // OPEQUALVERIFY
            && (txBytes[pos + 24] == 0xac); // OPCHECKSIG
    }

    function isP2SH(bytes txBytes, uint pos, uint script_len) returns (bool) {
        return (script_len == 23)           // 20 byte scripthash + 3 bytes of script
            && (txBytes[pos + 0] == 0xa9)   // OPHASH160
            && (txBytes[pos + 1] == 0x14)   // bytes to push
            && (txBytes[pos + 22] == 0x87); // OPEQUAL
    }

    function parseOutputScript(bytes txBytes, uint pos, uint script_len)
             returns (bytes20)
    {
        if (isP2PKH(txBytes, pos, script_len)) {
            return sliceBytes20(txBytes, pos + 3);
        } else if (isP2SH(txBytes, pos, script_len)) {
            return sliceBytes20(txBytes, pos + 2);
        } else {
            return;
        }
    }
}


// Idea: A briber wants Bitcoin miners to create empty blocks.
// By creating empty blocks - bitcoin's utility is reduced (as no transactions are confirmed).
// How do we prove that a block has no transactions in a cheap way? Easy!
// If a block contains NO transactions - then the coinbase is stored as the merkle root!
// So we just perform basic checks that a provided transaction "looks like a coinbase"
// And then check that the hash was indeed included as the merkle root!
// If so - pay the miner! Alo, we assume the coinbase output is pay to pubkey
// as we can extract the pubkey and convert it into an ethereum account!

// Furthermore - in our illustration - we can rely on the BTCRelay service to store and
// process Bitcoin's longest chain. We simply retrieve it from there; and perform basic checks.

// Future improvements: We can have a maturity period and only pay out once we have collected enough evidence
// i.e. 51/100 previous blocks are empty? Pay miners that supported the gold finger attack.
contract GoldFingerCon {

  address public owner; // Briber's address
  mapping (bytes32 => bool) public claimed; // Has this block number been claimed?
  mapping (bytes32 => BlockHeader) public blockHeaders; // We may only have to record a subset of information here.
  uint public bribe; // Extra ether sent per block
  uint public deposit;   // Briber's full deposit
  bytes32[] tips;
  uint public currentheight;
  BTC btc;

  bytes32[] orphans; // List of unconnected blocks
  modifier onlyOwner { require(msg.sender == owner); _;}

  event PayOut(bytes32 blockhash, address miner, uint bribe);
  event Block(bytes32 blockhash, uint ver, bytes32 parent, bytes32 root, uint time, uint bits, uint nonce, uint height, uint bestblock);
  event Deposit(address sender, uint coins);

  struct BlockHeader {
    //Header conents
    uint version;
    bytes32 parentHash;
    bytes32 merkleRoot;
    uint timestamp;
    uint bits;
    uint nonce;
    uint height; // local height from our checkpoint
    bytes32 blockhash;
  }


  // Set up the "starting height" upon creating the contract!
  // i.e. bribes can be claimed after this height...
  function GoldFingerCon(uint _bribe) {
    owner = msg.sender; bribe = _bribe; deposit = 0;
    btc = new BTC();
  }

  // Increase bribery deposit...
  function deposit() payable {
    Deposit(msg.sender, msg.value);
    deposit = deposit + msg.value;
  }

  // Anyone can submit blocks to be stored in this contract
  function submitBlock(bytes blockheader) returns (bool) {

    bytes32 blockhash = btc.flip32(sha256(sha256(blockheader))); // Hash of Block
    if(blockHeaders[blockhash].version > 0) { return false; } // Have we stored this block already?

    BlockHeader memory head = BlockHeader(0,0,0,0,0,0,0,blockhash); // Empty block header
    parseHeaderFields(head, blockheader); // Parse block header (fill BlockHeader Struct)

    // TODO: Check PoW here! 

    // Store block!
    blockHeaders[blockhash] = head;

    // Have we just received the first block?
    if(currentheight == 0) {
      if(owner != msg.sender) { return false; } // First block can only be submitted by owner of this contract.

      // Starting block i.e. a checkpoint for us!
      blockHeaders[blockhash].height = 1;
      tips.push(blockhash);
      currentheight = 1;
      // Tell the world we have stored it
      Block(blockhash, blockHeaders[blockhash].version, blockHeaders[blockhash].parentHash, blockHeaders[blockhash].merkleRoot, blockHeaders[blockhash].timestamp,
            blockHeaders[blockhash].bits, blockHeaders[blockhash].nonce, blockHeaders[blockhash].height, 2);
      return true;
    }

    // Do we have a previous block header?
    // TODO: Think about how to handle orphans that pass difficulty; but are before the checkpoint
    // We can only handle so many orphans within a single block.
    // Might be worth giving briber power to "clear" orphan list.
    // Shouldn't impact chain with highest PoW anyway (which hopefully will be the bribers empty blocks).
    if(blockHeaders[head.parentHash].version == 0) {

      // Do not store too many orphans.
      // TODO: Work out gas costs for maximum orphan allowance which is "how many times can we run evaluate block"
      // Only involves two if statements really... so can probably store hundreds or thousands here.
      if(orphans.length > 10) {
        return false;
      }

      // Nope... store as orphan for now.
      orphans.push(head.blockhash);

      // Tell the world we have stored it
      Block(blockhash, blockHeaders[blockhash].version, blockHeaders[blockhash].parentHash, blockHeaders[blockhash].merkleRoot,
            blockHeaders[blockhash].timestamp, blockHeaders[blockhash].bits, blockHeaders[blockhash].nonce, 999999999999, 0);
      return true;
    }

    return evaluateBlock(blockhash);

  }

  function evaluateOrphans(){

    // While we are making progress and have gas... lets continue it!
    while(orphanProgress() && (msg.gas > 500000)) {}
  }

  function orphanProgress() returns (bool) {
    bytes32[] memory stillOrphan = new bytes32[](orphans.length);
    uint orphanC = 0;
    bool madeprogress = false;
    // Go through orphans... check if any are now "the best"
    for(uint i=0; i<orphans.length; i++) {
      madeprogress = evaluateBlock(orphans[i]);
      // Did we resolve the orphanness?
      if(!madeprogress) {
        // Keep as it didn't get anywhere.
        // We use blockhash from storage - to avoid pointer issues.
        stillOrphan[orphanC] = blockHeaders[orphans[i]].blockhash;
        orphanC = orphanC + 1;
      } else {

        // Did we find a height that is further than tip?
        if(blockHeaders[orphans[i]].height > currentheight) {
          evaluateBlock(orphans[i]); // Use one in storage (most up to date)
          // Regardless; we have connected it to the blockchain... and it wasnt further!
        }
      }
    }

    delete orphans;

    // Keep copy of orphans we could not settle!
    for(i=0; i<stillOrphan.length; i++) {
      if(blockHeaders[stillOrphan[i]].version != 0) {
        orphans.push(stillOrphan[i]); // TODO: Check if this makes copy; or just references address
      } else {
        break; // Reached end of the list.
      }
    }

    return madeprogress;
  }

  // Try and fit the block somewhere in our storage..
  function evaluateBlock(bytes32 head) internal returns (bool) {

    bool foundnewtip = false;
    for(uint i=0; i<tips.length; i++) {
      // Build upon our current tip?
      if(blockHeaders[tips[i]].blockhash == blockHeaders[head].parentHash || blockHeaders[head].height > currentheight) {

        // Yes it does build upon tip... does the block height make sense?
        // OK so prev hash is ok. block height is ok.
        // Some sanity checks like difficulty, timestamp, etc is missing.
        foundnewtip = true;
        break;
      }
    }

    // Did we find the new tip of the blockchain?
    if(foundnewtip) {
      delete tips;
      currentheight = currentheight + 1;
      blockHeaders[head].height = currentheight;
      tips.push(head);
      
      // Tell the world we have stored it
      Block(blockHeaders[head].blockhash, blockHeaders[head].version, blockHeaders[head].parentHash,
            blockHeaders[head].merkleRoot, blockHeaders[head].timestamp, blockHeaders[head].bits, blockHeaders[head].nonce, blockHeaders[head].height, 1);
      return true;
    }

    // Do we at least have a previous block header?
    if(blockHeaders[head].version != 0 && blockHeaders[head].height == 0) {

      // If we did not store this block header...
      // this orphan will be deleted from temp storage
      if(findHeight(blockHeaders[head].blockhash)) {
        Block(blockHeaders[head].blockhash, blockHeaders[head].version, blockHeaders[head].parentHash, blockHeaders[head].merkleRoot,
              blockHeaders[head].timestamp, blockHeaders[head].bits, blockHeaders[head].nonce, blockHeaders[head].height, 0);
      }
    }

    // We have had no luck... Still an orphan
    // Or we do not know its height
    return false;

  }

  // We may receive orphans... and we need to figure out their height once we connect them!
  function findHeight(bytes32 head) returns (bool) {

    bytes32 lastchecked = head;

    // Go back 20 blocks.... try and find a height
    for(uint i=1; i<=20; i++) {
      bytes32 parent = blockHeaders[lastchecked].parentHash;

      // Lets make sure it exists..
      if(blockHeaders[parent].version > 0) {
        if(blockHeaders[parent].height != 0) {
          // Imagine it was immediate parent...
          // Parent_height = 89, i = 1.
          // Head height is 90!
          blockHeaders[head].height = blockHeaders[parent].height + i;
          return true;
        }
      }
    }

    return false;
  }

  function acceptBribe(bytes32 blockhash, bytes coinbase) returns (bool) {
    if(claimed[blockhash]) { return false; }
    if(blockHeaders[tips[0]].version == 0) { return false; }

    // Fetch block header.
    BlockHeader memory head = blockHeaders[blockhash];

    // Confirm block header is saved; and it has at least six confirmations
    /*if(head.height == 0 || head.height > currentheight-6) { return false; }*/

    bytes32 coinbasetxhash = btc.flip32(sha256(sha256(coinbase))); //coinbase tx hash

    // Check that the coinbase tx hash is the merkle tree root in block header
    // This means the block is empty!
    if(head.merkleRoot == coinbasetxhash) {

      // Fetch Ethereum Account
      // DISCLAIMER: Not tested whether it comptues correct address,
      // but provides "somewhat" gas cost for what we want to do!
      address payminer = btc.getEthereumAccountFromPubKey(coinbase);

      claimed[blockhash] = true;
      PayOut(blockhash, payminer, bribe);

      // Failed to send? Reset it.
      if(!payminer.send(bribe)) {
        claimed[blockhash] = false;
      }

      return true;
    }

    return false;
  }

  function parseHeaderFields(BlockHeader head, bytes header) internal {
    bytes32 out;
    uint8[6] memory indecies = [0,4,36,68,72,76]; //Offsets of each field

    // Fetch the small values
    head.version = btc.getBytesLE(header, indecies[0], 32);
    head.timestamp = btc.getBytesLE(header, indecies[3], 32);
    head.bits = btc.getBytesLE(header, indecies[4], 32);
    head.nonce = btc.getBytesLE(header, indecies[5], 32);
    uint index = indecies[2];
    assembly {
      out := mload(add(header, index))
    }

    // Fetch parent hash and merkle root!
    head.parentHash = btc.flip32(out);

    index = indecies[3];
    assembly {
      out := mload(add(header, index))
    }

    head.merkleRoot = btc.flip32(out);
  }

/*
  // FOR TESTING PURPOSES: WE WILL NOT USE THIS SO COMMENT IT OUT
  function testParsing(bytes header, bytes coinbase) returns (uint, bytes32, bytes32, uint, uint, uint, uint, bytes20) {

    // Make sure bribes are ready to be accepted
    if(!activated) { return false; }
    // We will search 200 past blocks....
    BlockHeader memory head;
    head = parseBlock(header);
    uint val = 0;
    bytes20 hashkey = 0;

    (val, hashkey) = btc.getFirstOutput(coinbase);
    return (head.version, head.parentHash, head.merkleRoot, head.timestamp, head.bits, head.nonce, val, hashkey);
  }
*/

}
