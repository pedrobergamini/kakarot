%lang starknet

from utils.utils import Helpers
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.cairo_secp.signature import verify_eth_signature_uint256
from starkware.starknet.common.syscalls import get_tx_info
from starkware.cairo.common.uint256 import Uint256
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.math import split_felt
from starkware.cairo.common.cairo_keccak.keccak import keccak, finalize_keccak, keccak_bigend
from utils.rlp import RLP
from starkware.cairo.common.math_cmp import is_le

namespace ExternallyOwnedAccount {
    // Constants
    // keccak250(ascii('execute_at_address'))
    const EXECUTE_AT_ADDRESS_SELECTOR = 175332271055223547208505378209204736960926292802627036960758298143252682610;
    // @dev see utils/InterfaceId.sol
    const INTERFACE_ID = 0x68bca1a;
    const TX_ITEMS = 12;  // number of elements in an evm tx see EIP 1559

    // Indexes to retrieve specific data from the EVM transaction
    // @dev Should be used (eg: `items[CHAIN_ID_IDX]`)
    const CHAIN_ID_IDX = 0;
    const NONCE_IDX = 1;
    const MAX_PRIORITY_FEE_PER_GAS_IDX = 2;
    const MAX_FEE_PER_GAS_IDX = 3;
    const GAS_LIMIT_IDX = 4;
    const DESTINATION_IDX = 5;
    const AMOUNT_IDX = 6;
    const PAYLOAD_IDX = 7;
    const ACCESS_LIST_IDX = 8;
    const V_IDX = 9;
    const R_IDX = 10;
    const S_IDX = 11;

    // @dev 2 * len_byte + 2 * string_len (32) + v
    const SIGNATURE_LEN = 67;

    struct Call {
        to: felt,
        selector: felt,
        calldata_len: felt,
        calldata: felt*,
    }

    // Tmp struct introduced while we wait for Cairo to support passing `[Call]` to __execute__
    struct CallArray {
        to: felt,
        selector: felt,
        data_offset: felt,
        data_len: felt,
    }

    // @notice checks if tx is signed and valid for each call
    // @param eth_address The ethereum address owning this account
    // @param call_array_len The length of the call array
    // @param call_array The call array
    // @param calldata_len The length of the calldata
    // @param calldata The calldata
    func validate{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        bitwise_ptr: BitwiseBuiltin*,
        range_check_ptr,
    }(
        eth_address: felt,
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) -> () {
        alloc_locals;
        if (call_array_len == 0) {
            return ();
        }

        local _call: Call = Call(
            to=[call_array].to,
            selector=[call_array].selector,
            calldata_len=[call_array].data_len,
            calldata=calldata + [call_array].data_offset,
            );

        is_valid_eth_tx(eth_address, _call.calldata_len, _call.calldata);

        return validate(
            eth_address=eth_address,
            call_array_len=call_array_len - 1,
            call_array=call_array + CallArray.SIZE,
            calldata_len=calldata_len,
            calldata=calldata,
        );
    }

    // @notice decodes evm tx and validates it
    // @dev 1. decodes the tx list
    // @dev 2. recodes the list without the signature
    // @dev 3. hashes the tx
    // @dev 4. verifies the signature
    // @dev TODO https://github.com/Flydexo/kakarot-eth-aa/issues/6
    // @param eth_address The ethereum address owning the account
    // @param calldata_len The lenght of the calldata
    // @param calldata The calldata
    // @return is_valid 1 if the transaction is valid
    func is_valid_eth_tx{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        bitwise_ptr: BitwiseBuiltin*,
        range_check_ptr,
    }(eth_address: felt, calldata_len: felt, calldata: felt*) -> (is_valid: felt) {
        alloc_locals;
        let tx_type = [calldata];
        // remove the tx type
        let rlp_data = calldata + 1;
        let (local items: RLP.Item*) = alloc();
        // decode the rlp array
        RLP.decode_rlp(calldata_len - 1, rlp_data, items);
        // eip 1559 tx only for the moment
        if (tx_type == 2) {
            // remove the sig to hash the tx
            let data_len: felt = [items].data_len - SIGNATURE_LEN;
            let (list_ptr: felt*) = alloc();
            // add the tx type, see here: https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1559.md#specification
            assert [list_ptr] = tx_type;
            // encode the rlp list without the sig
            let (rlp_len: felt) = RLP.encode_rlp_list(data_len, [items].data, list_ptr + 1);
            let (keccak_ptr: felt*) = alloc();
            let keccak_ptr_start = keccak_ptr;
            let (words: felt*) = alloc();
            // transforms bytes to groups of 64 bits (used for hashing)
            Helpers.bytes_to_bytes8_little_endian(
                bytes_len=rlp_len + 1,
                bytes=list_ptr,
                index=0,
                size=rlp_len + 1,
                bytes8=0,
                bytes8_shift=0,
                dest=words,
                dest_index=0,
            );
            // keccak_bigend because verify_eth_signature_uint256 requires bigend
            let tx_hash = keccak_bigend{keccak_ptr=keccak_ptr}(inputs=words, n_bytes=rlp_len + 1);
            let (local sub_items: RLP.Item*) = alloc();
            // decode the rlp elements in the tx (was in the list element)
            RLP.decode_rlp([items].data_len, [items].data, sub_items);
            let v = Helpers.bytes_to_felt(sub_items[V_IDX].data_len, sub_items[V_IDX].data, 0);
            let r = Helpers.bytes32_to_uint256(sub_items[R_IDX].data);
            let s = Helpers.bytes32_to_uint256(sub_items[S_IDX].data);
            finalize_keccak(keccak_ptr_start=keccak_ptr_start, keccak_ptr_end=keccak_ptr);
            return is_valid_eth_signature(tx_hash.res, r, s, v.n, eth_address);
        } else {
            assert 1 = 0;
            return (is_valid=0);
        }
    }

    // @notice returns 1 (true) and does not fail if the signature is valid
    // @param hash The Hash to verify if signed
    // @param v, r, s The signature
    // @param eth_address The ethereum address to compare the signature
    // @return is_valid 1 if the signature is valid
    func is_valid_eth_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        bitwise_ptr: BitwiseBuiltin*,
        range_check_ptr,
    }(msg_hash: Uint256, r: Uint256, s: Uint256, v: felt, eth_address: felt) -> (is_valid: felt) {
        alloc_locals;
        let (keccak_ptr: felt*) = alloc();
        local keccak_ptr_start: felt* = keccak_ptr;
        with keccak_ptr {
            verify_eth_signature_uint256(msg_hash=msg_hash, r=r, s=s, v=v, eth_address=eth_address);
        }
        finalize_keccak(keccak_ptr_start, keccak_ptr);
        return (is_valid=1);
    }

    func is_valid_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        bitwise_ptr: BitwiseBuiltin*,
        range_check_ptr,
    }(_eth_address: felt, hash_len: felt, hash: felt*, signature_len: felt, signature: felt*) -> (
        is_valid: felt
    ) {
        alloc_locals;
        let v = signature[0];
        let r: Uint256 = Uint256(low=signature[1], high=signature[2]);
        let s: Uint256 = Uint256(low=signature[3], high=signature[4]);
        let msg_hash: Uint256 = Uint256(low=hash[0], high=hash[1]);
        return ExternallyOwnedAccount.is_valid_eth_signature(msg_hash, r, s, v, _eth_address);
    }
}
