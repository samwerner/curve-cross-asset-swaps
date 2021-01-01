# @version 0.2.8

from vyper.interfaces import ERC20
from vyper.interfaces import ERC721

implements: ERC721


interface AddressProvider:
    def get_registry() -> address: view
    def get_address(_id: uint256) -> address: view

interface Curve:
    def get_dy(i: int128, j: int128, dx: uint256) -> uint256: view

interface Registry:
    def get_coins(_pool: address) -> address[8]: view
    def get_coin_indices(pool: address, _from: address, _to: address) -> (int128, int128, bool): view

interface RegistrySwap:
    def exchange(
        _pool: address,
        _from: address,
        _to: address,
        _amount: uint256,
        _expected: uint256,
        _receiver: address,
    ) -> uint256: payable

interface Synth:
    def currencyKey() -> bytes32: nonpayable

interface Exchanger:
    def getAmountsForExchange(
        sourceAmount: uint256,
        sourceCurrencyKey: bytes32,
        destinationCurrencyKey: bytes32
    ) -> (uint256, uint256, uint256): view
    def maxSecsLeftInWaitingPeriod(account: address, currencyKey: bytes32) -> uint256: view
    def settle(user: address, currencyKey: bytes32): nonpayable

interface Settler:
    def initialize(): nonpayable
    def synth() -> address: view
    def time_to_settle() -> uint256: view
    def exchange_via_snx(
        _target: address,
        _amount: uint256,
        _source_key: bytes32,
        _dest_key: bytes32
    ) -> bool: nonpayable
    def exchange_via_curve(
        _target: address,
        _pool: address,
        _amount: uint256,
        _expected: uint256,
        _receiver: address,
    ) -> uint256: nonpayable
    def withdraw(_receiver: address, _amount: uint256) -> uint256: nonpayable

interface ERC721Receiver:
    def onERC721Received(
            _operator: address,
            _from: address,
            _tokenId: uint256,
            _data: Bytes[1024]
        ) -> bytes32: view


event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    tokenId: indexed(uint256)

event Approval:
    owner: indexed(address)
    approved: indexed(address)
    tokenId: indexed(uint256)

event ApprovalForAll:
    owner: indexed(address)
    operator: indexed(address)
    approved: bool


struct TokenInfo:
    owner: address
    synth: address
    underlying_balance: uint256
    time_to_settle: uint256


ADDRESS_PROVIDER: constant(address) = 0x0000000022D53366457F9d5E68Ec105046FC4383
EXCHANGER: constant(address) = 0x0bfDc04B38251394542586969E2356d0D731f7DE

# @dev Mapping from NFT ID to the address that owns it.
idToOwner: HashMap[uint256, address]

# @dev Mapping from NFT ID to approved address.
idToApprovals: HashMap[uint256, address]

# @dev Mapping from owner address to count of his tokens.
ownerToNFTokenCount: HashMap[address, uint256]

# @dev Mapping from owner address to mapping of operator addresses.
ownerToOperators: HashMap[address, HashMap[address, bool]]

settler_implementation: address
settler_proxies: address[4294967296]
settler_count: uint256

# synth -> curve pool where it can be traded
synth_pools: public(HashMap[address, address])
# coin -> synth that it can be swapped for
swappable_synth: public(HashMap[address, address])
# coin -> spender -> is approved?
is_approved: HashMap[address, HashMap[address, bool]]
# synth -> currency key
currency_keys: HashMap[address, bytes32]
# token id -> is synth settled?
is_settled: public(HashMap[uint256, bool])

@external
def __init__(_settler_implementation: address):
    """
    @dev Contract constructor.
    """
    self.settler_implementation = _settler_implementation


@view
@external
def supportsInterface(_interfaceID: bytes32) -> bool:
    """
    @dev Interface identification is specified in ERC-165.
    @param _interfaceID Id of the interface
    """
    return _interfaceID in [
        0x0000000000000000000000000000000000000000000000000000000001ffc9a7,  # ERC165
        0x0000000000000000000000000000000000000000000000000000000080ac58cd,  # ERC721
    ]


@view
@external
def balanceOf(_owner: address) -> uint256:
    """
    @dev Returns the number of NFTs owned by `_owner`.
         Throws if `_owner` is the zero address. NFTs assigned to the zero address are considered invalid.
    @param _owner Address for whom to query the balance.
    """
    assert _owner != ZERO_ADDRESS
    return self.ownerToNFTokenCount[_owner]


@view
@external
def ownerOf(_tokenId: uint256) -> address:
    """
    @dev Returns the address of the owner of the NFT.
         Throws if `_tokenId` is not a valid NFT.
    @param _tokenId The identifier for an NFT.
    """
    owner: address = self.idToOwner[_tokenId]
    # Throws if `_tokenId` is not a valid NFT
    assert owner != ZERO_ADDRESS
    return owner


@view
@external
def getApproved(_tokenId: uint256) -> address:
    """
    @dev Get the approved address for a single NFT.
         Throws if `_tokenId` is not a valid NFT.
    @param _tokenId ID of the NFT to query the approval of.
    """
    # Throws if `_tokenId` is not a valid NFT
    assert self.idToOwner[_tokenId] != ZERO_ADDRESS
    return self.idToApprovals[_tokenId]


@view
@external
def isApprovedForAll(_owner: address, _operator: address) -> bool:
    """
    @dev Checks if `_operator` is an approved operator for `_owner`.
    @param _owner The address that owns the NFTs.
    @param _operator The address that acts on behalf of the owner.
    """
    return (self.ownerToOperators[_owner])[_operator]


@internal
def _transfer(_from: address, _to: address, _tokenId: uint256, _caller: address):
    assert _from != ZERO_ADDRESS
    assert _to != ZERO_ADDRESS
    owner: address = self.idToOwner[_tokenId]
    assert owner == _from

    approved_for: address = self.idToApprovals[_tokenId]
    if _caller != _from:
        assert approved_for == _caller or self.ownerToOperators[owner][_caller]

    if approved_for != ZERO_ADDRESS:
        self.idToApprovals[_tokenId] = ZERO_ADDRESS

    self.idToOwner[_tokenId] = _to
    self.ownerToNFTokenCount[_from] -= 1
    self.ownerToNFTokenCount[_to] += 1

    log Transfer(_from, _to, _tokenId)


@external
def transferFrom(_from: address, _to: address, _tokenId: uint256):
    """
    @dev Throws unless `msg.sender` is the current owner, an authorized operator, or the approved
         address for this NFT.
         Throws if `_from` is not the current owner.
         Throws if `_to` is the zero address.
         Throws if `_tokenId` is not a valid NFT.
    @notice The caller is responsible to confirm that `_to` is capable of receiving NFTs or else
            they maybe be permanently lost.
    @param _from The current owner of the NFT.
    @param _to The new owner.
    @param _tokenId The NFT to transfer.
    """
    self._transfer(_from, _to, _tokenId, msg.sender)


@external
def safeTransferFrom(
        _from: address,
        _to: address,
        _tokenId: uint256,
        _data: Bytes[1024]=b""
    ):
    """
    @dev Transfers the ownership of an NFT from one address to another address.
         Throws unless `msg.sender` is the current owner, an authorized operator, or the
         approved address for this NFT.
         Throws if `_from` is not the current owner.
         Throws if `_to` is the zero address.
         Throws if `_tokenId` is not a valid NFT.
         If `_to` is a smart contract, it calls `onERC721Received` on `_to` and throws if
         the return value is not `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`.
         NOTE: bytes4 is represented by bytes32 with padding
    @param _from The current owner of the NFT.
    @param _to The new owner.
    @param _tokenId The NFT to transfer.
    @param _data Additional data with no specified format, sent in call to `_to`.
    """
    self._transfer(_from, _to, _tokenId, msg.sender)
    if _to.is_contract: # check if `_to` is a contract address
        returnValue: bytes32 = ERC721Receiver(_to).onERC721Received(msg.sender, _from, _tokenId, _data)
        # Throws if transfer destination is a contract which does not implement 'onERC721Received'
        assert returnValue == method_id("onERC721Received(address,address,uint256,bytes)", output_type=bytes32)


@external
def approve(_approved: address, _tokenId: uint256):
    """
    @dev Set or reaffirm the approved address for an NFT. The zero address indicates there is no approved address.
         Throws unless `msg.sender` is the current NFT owner, or an authorized operator of the current owner.
         Throws if `_tokenId` is not a valid NFT. (NOTE: This is not written the EIP)
         Throws if `_approved` is the current owner. (NOTE: This is not written the EIP)
    @param _approved Address to be approved for the given NFT ID.
    @param _tokenId ID of the token to be approved.
    """
    owner: address = self.idToOwner[_tokenId]
    # Throws if `_tokenId` is not a valid NFT
    assert owner != ZERO_ADDRESS
    # Throws if `_approved` is the current owner
    assert _approved != owner
    # Check requirements
    senderIsOwner: bool = self.idToOwner[_tokenId] == msg.sender
    senderIsApprovedForAll: bool = (self.ownerToOperators[owner])[msg.sender]
    assert (senderIsOwner or senderIsApprovedForAll)
    # Set the approval
    self.idToApprovals[_tokenId] = _approved
    log Approval(owner, _approved, _tokenId)


@external
def setApprovalForAll(_operator: address, _approved: bool):
    """
    @dev Enables or disables approval for a third party ("operator") to manage all of
         `msg.sender`'s assets. It also emits the ApprovalForAll event.
         Throws if `_operator` is the `msg.sender`. (NOTE: This is not written the EIP)
    @notice This works even if sender doesn't own any tokens at the time.
    @param _operator Address to add to the set of authorized operators.
    @param _approved True if the operators is approved, false to revoke approval.
    """
    # Throws if `_operator` is the `msg.sender`
    assert _operator != msg.sender
    self.ownerToOperators[msg.sender][_operator] = _approved
    log ApprovalForAll(msg.sender, _operator, _approved)


@view
@external
def get_swap_into_synth_amount(_from: address, _synth: address, _amount: uint256) -> uint256:
    registry: address = AddressProvider(ADDRESS_PROVIDER).get_registry()

    intermediate_synth: address = self.swappable_synth[_from]
    pool: address = self.synth_pools[intermediate_synth]

    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    i, j, is_underlying = Registry(registry).get_coin_indices(pool, _from, intermediate_synth)

    received: uint256 = Curve(pool).get_dy(i, j, _amount)

    return Exchanger(EXCHANGER).getAmountsForExchange(
        received,
        self.currency_keys[intermediate_synth],
        self.currency_keys[_synth],
    )[0]


@view
@external
def get_swap_from_synth_amount(_synth: address, _to: address, _amount: uint256) -> uint256:
    registry: address = AddressProvider(ADDRESS_PROVIDER).get_registry()
    pool: address = self.synth_pools[_synth]

    i: int128 = 0
    j: int128 = 0
    is_underlying: bool = False
    i, j, is_underlying = Registry(registry).get_coin_indices(pool, _synth, _to)

    return Curve(pool).get_dy(i, j, _amount)


@payable
@external
def swap_into_synth(
    _from: address,
    _synth: address,
    _amount: uint256,
    _expected: uint256,
    _receiver: address = msg.sender,
    _token_id: uint256 = 0,
) -> uint256:

    settler: address = convert(_token_id, address)
    if settler == ZERO_ADDRESS:
        count: uint256 = self.settler_count
        if count == 0:
            settler = create_forwarder_to(self.settler_implementation)
            Settler(settler).initialize()
        else:
            count -= 1
            settler = self.settler_proxies[count]
            self.settler_count = count
    else:
        assert msg.sender == self.idToOwner[_token_id]
        assert msg.sender == _receiver
        assert Settler(settler).synth() == _synth

    registry_swap: address = AddressProvider(ADDRESS_PROVIDER).get_address(2)
    if _from != 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE:
        response: Bytes[32] = raw_call(
            _from,
            concat(
                method_id("transferFrom(address,address,uint256)"),
                convert(msg.sender, bytes32),
                convert(self, bytes32),
                convert(_amount, bytes32),
            ),
            max_outsize=32,
        )
        if len(response) != 0:
            assert convert(response, bool)
        if not self.is_approved[_from][registry_swap]:
            response = raw_call(
                _from,
                concat(
                    method_id("approve(address,uint256)"),
                    convert(registry_swap, bytes32),
                    convert(MAX_UINT256, bytes32),
                ),
                max_outsize=32,
            )
            if len(response) != 0:
                assert convert(response, bool)
            self.is_approved[_from][registry_swap] = True

    intermediate_synth: address = self.swappable_synth[_from]
    pool: address = self.synth_pools[intermediate_synth]

    received: uint256 = RegistrySwap(registry_swap).exchange(
        pool,
        _from,
        intermediate_synth,
        _amount,
        0,
        settler,
        value=msg.value
    )

    initial_balance: uint256 = ERC20(_synth).balanceOf(settler)
    Settler(settler).exchange_via_snx(
        _synth,
        received,
        self.currency_keys[intermediate_synth],
        self.currency_keys[_synth]
    )
    assert ERC20(_synth).balanceOf(settler) - initial_balance >= _expected, "Rekt by slippage"

    token_id: uint256 = convert(settler, uint256)
    self.is_settled[token_id] = False
    if _token_id == 0:
        self.idToOwner[token_id] = _receiver
        self.ownerToNFTokenCount[_receiver] += 1
        log Transfer(ZERO_ADDRESS, _receiver, token_id)

    return token_id


@external
def swap_from_synth(
    _token_id: uint256,
    _target: address,
    _amount: uint256,
    _expected: uint256,
    _receiver: address = msg.sender,
) -> uint256:
    assert msg.sender == self.idToOwner[_token_id]

    settler: address = convert(_token_id, address)
    synth: address = self.swappable_synth[_target]
    pool: address = self.synth_pools[synth]

    if not self.is_settled[_token_id]:
        currency_key: bytes32 = self.currency_keys[synth]
        Exchanger(EXCHANGER).settle(settler, currency_key)
        self.is_settled[_token_id] = True

    remaining_balance: uint256 = Settler(settler).exchange_via_curve(_target, pool, _amount, _expected, _receiver)

    if remaining_balance == 0:
        self.idToOwner[_token_id] = ZERO_ADDRESS
        self.idToApprovals[_token_id] = ZERO_ADDRESS
        self.ownerToNFTokenCount[msg.sender] -= 1
        count: uint256 = self.settler_count
        self.settler_proxies[count] = settler
        self.settler_count = count + 1
        log Transfer(msg.sender, ZERO_ADDRESS, _token_id)

    return remaining_balance


@external
def withdraw(_token_id: uint256, _amount: uint256, _receiver: address = msg.sender) -> uint256:
    assert msg.sender == self.idToOwner[_token_id]

    settler: address = convert(_token_id, address)

    if not self.is_settled[_token_id]:
        synth: address = Settler(settler).synth()
        currency_key: bytes32 = self.currency_keys[synth]
        Exchanger(EXCHANGER).settle(settler, currency_key)
        self.is_settled[_token_id] = True

    remaining_balance: uint256 = Settler(settler).withdraw(_receiver, _amount)

    if remaining_balance == 0:
        self.idToOwner[_token_id] = ZERO_ADDRESS
        self.idToApprovals[_token_id] = ZERO_ADDRESS
        self.ownerToNFTokenCount[msg.sender] -= 1
        count: uint256 = self.settler_count
        self.settler_proxies[count] = settler
        self.settler_count = count + 1
        log Transfer(msg.sender, ZERO_ADDRESS, _token_id)

    return remaining_balance


@external
def settle(_token_id: uint256) -> bool:
    if not self.is_settled[_token_id]:
        assert self.idToOwner[_token_id] != ZERO_ADDRESS, "Unknown Token ID"

        settler: address = convert(_token_id, address)
        synth: address = Settler(settler).synth()
        currency_key: bytes32 = self.currency_keys[synth]
        Exchanger(EXCHANGER).settle(settler, currency_key)  # dev: settlement failed
        self.is_settled[_token_id] = True

    return True


@external
def add_synth(_synth: address, _pool: address):
    assert self.synth_pools[_synth] == ZERO_ADDRESS  # dev: already added

    # this will revert if `_synth` is not actually a synth
    self.currency_keys[_synth] = Synth(_synth).currencyKey()

    registry: address = AddressProvider(ADDRESS_PROVIDER).get_registry()
    pool_coins: address[8] = Registry(registry).get_coins(_pool)

    has_synth: bool = False
    for coin in pool_coins:
        if coin == ZERO_ADDRESS:
            assert has_synth  # dev: synth not in pool
            break
        if coin == _synth:
            self.synth_pools[_synth] = _pool
            has_synth = True
        else:
            self.swappable_synth[coin] = _synth


@view
@external
def token_info(_token_id: uint256) -> TokenInfo:
    info: TokenInfo = empty(TokenInfo)
    info.owner = self.idToOwner[_token_id]
    assert info.owner != ZERO_ADDRESS

    settler: address = convert(_token_id, address)
    info.synth = Settler(settler).synth()
    info.underlying_balance = ERC20(info.synth).balanceOf(settler)
    info.time_to_settle = Exchanger(EXCHANGER).maxSecsLeftInWaitingPeriod(settler, self.currency_keys[info.synth])

    return info