import brownie
import pytest


@pytest.fixture(scope="module", autouse=True)
def setup(alice, swap, DAI, USDT, add_synths):
    DAI._mint_for_testing(alice, 1_000_000 * 10 ** 18)
    DAI.approve(swap, 2**256-1, {'from': alice})
    USDT._mint_for_testing(alice, 1_000_000 * 10 ** 6)
    USDT.approve(swap, 2**256-1, {'from': alice})


def test_swap_into_existing_increases_balance(swap, alice, DAI, sUSD, sBTC, settler_sbtc):
    initial = sBTC.balanceOf(settler_sbtc)

    amount = 1_000_000 * 10 ** 18
    expected = swap.get_swap_into_synth_amount(DAI, sBTC, amount)
    tx = swap.swap_into_synth(DAI, sBTC, amount, 0, alice, settler_sbtc.token_id(), {'from': alice})

    assert DAI.balanceOf(alice) == 0
    assert DAI.balanceOf(swap) == 0
    assert DAI.balanceOf(settler_sbtc) == 0

    assert sUSD.balanceOf(alice) == 0
    assert sUSD.balanceOf(swap) == 0
    assert sUSD.balanceOf(settler_sbtc) == 0

    assert sBTC.balanceOf(alice) == 0
    assert sBTC.balanceOf(swap) == 0
    assert sBTC.balanceOf(settler_sbtc) == expected + initial


def test_swap_into_existing_does_not_mint(swap, alice, DAI, sBTC, settler_sbtc):
    initial = sBTC.balanceOf(settler_sbtc)

    amount = 1_000_000 * 10 ** 18
    expected = swap.get_swap_into_synth_amount(DAI, sBTC, amount)
    tx = swap.swap_into_synth(DAI, sBTC, amount, 0, alice, settler_sbtc.token_id(), {'from': alice})
    token_id = tx.return_value

    assert not tx.new_contracts
    assert token_id == settler_sbtc.token_id()
    assert swap.balanceOf(alice) == 1


def test_only_owner(swap, alice, bob, DAI, sBTC, settler_sbtc):
    amount = 1_000_000 * 10 ** 18

    with brownie.reverts():
        swap.swap_into_synth(DAI, sBTC, amount, 0, bob, settler_sbtc.token_id(), {'from': bob})


def test_wrong_receiver(swap, alice, bob, DAI, sBTC, settler_sbtc):
    amount = 1_000_000 * 10 ** 18

    with brownie.reverts():
        swap.swap_into_synth(DAI, sBTC, amount, 0, bob, settler_sbtc.token_id(), {'from': alice})


def test_wrong_synth(swap, alice, DAI, sETH, settler_sbtc):
    amount = 1_000_000 * 10 ** 18

    with brownie.reverts():
        swap.swap_into_synth(DAI, sETH, amount, 0, alice, settler_sbtc.token_id(), {'from': alice})


def test_cannot_add_after_burn(chain, swap, alice, settler_sbtc, DAI, sBTC):
    chain.mine(timedelta=300)
    token_id = settler_sbtc.token_id()
    balance = swap.token_info(token_id)['underlying_balance']

    swap.withdraw(token_id, balance, {'from': alice})

    with brownie.reverts():
        swap.swap_into_synth(DAI, sBTC, 10**18, 0, alice, token_id, {'from': alice})