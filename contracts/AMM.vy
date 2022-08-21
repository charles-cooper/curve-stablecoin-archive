# @version 0.3.6

interface ERC20:
    def transfer(_to: address, _value: uint256) -> bool: nonpayable
    def transferFrom(_from: address, _to: address, _value: uint256) -> bool: nonpayable
    def decimals() -> uint256: view
    def balanceOf(_user: address) -> uint256: view
    def approve(_spender: address, _value: uint256) -> bool: nonpayable

interface PriceOracle:
    def price() -> uint256: view
    def price_w() -> uint256: nonpayable


event TokenExchange:
    buyer: indexed(address)
    sold_id: uint256
    tokens_sold: uint256
    bought_id: uint256
    tokens_bought: uint256

event Deposit:
    provider: indexed(address)
    amount: uint256
    n1: int256
    n2: int256

event Withdraw:
    provider: indexed(address)
    receiver: address
    amount_borrowed: uint256
    amount_collateral: uint256

event SetRate:
    rate: uint256
    rate_mul: uint256
    time: uint256

event SetFee:
    fee: uint256

event SetAdminFee:
    fee: uint256

event SetPriceOracle:
    price_oracle: address


MAX_TICKS: constant(int256) = 50
MAX_TICKS_UINT: constant(uint256) = 50
MAX_SKIP_TICKS: constant(int256) = 1024

struct UserTicks:
    ns: int256  # packs n1 and n2, each is int128
    ticks: uint256[MAX_TICKS/2]  # Share fractions packed 2 per slot

struct DetailedTrade:
    in_amount: uint256
    out_amount: uint256
    n1: int256
    n2: int256
    ticks_in: uint256[MAX_TICKS]
    last_tick_j: uint256

BORROWED_TOKEN: immutable(ERC20)    # x
BORROWED_PRECISION: immutable(uint256)
COLLATERAL_TOKEN: immutable(ERC20)  # y
COLLATERAL_PRECISION: immutable(uint256)
BASE_PRICE: immutable(uint256)
ADMIN: immutable(address)

A: immutable(uint256)
Aminus1: immutable(uint256)
A2: immutable(uint256)
Aminus12: immutable(uint256)
SQRT_BAND_RATIO: immutable(uint256)  # sqrt(A / (A - 1))
LOG_A_RATIO: immutable(int256)  # ln(A / (A - 1))

MAX_FEE: constant(uint256) = 10**17  # 10%
MAX_ADMIN_FEE: constant(uint256) = 10**18  # 100%


fee: public(uint256)
admin_fee: public(uint256)
rate: public(uint256)
rate_time: uint256
rate_mul: public(uint256)
active_band: public(int256)
min_band: int256
max_band: int256

price_oracle_contract: public(PriceOracle)

bands_x: public(HashMap[int256, uint256])
bands_y: public(HashMap[int256, uint256])

total_shares: HashMap[int256, uint256]
user_shares: HashMap[address, UserTicks]


@external
def __init__(
        _borrowed_token: address,
        _borrowed_precision: uint256,
        _collateral_token: address,
        _collateral_precision: uint256,
        _A: uint256,
        _sqrt_band_ratio: uint256,
        _log_A_ratio: int256,
        _base_price: uint256,
        fee: uint256,
        admin: address,
        admin_fee: uint256,
        _price_oracle_contract: address,
    ):
    BORROWED_TOKEN = ERC20(_borrowed_token)
    BORROWED_PRECISION = _borrowed_precision
    COLLATERAL_TOKEN = ERC20(_collateral_token)
    COLLATERAL_PRECISION = _collateral_precision
    A = _A
    BASE_PRICE = _base_price

    Aminus1 = unsafe_sub(A, 1)
    A2 = pow_mod256(A, 2)
    Aminus12 = pow_mod256(unsafe_sub(A, 1), 2)

    self.fee = fee
    self.admin_fee = admin_fee
    self.price_oracle_contract = PriceOracle(_price_oracle_contract)

    self.rate_mul = 10**18

    # sqrt(A / (A - 1)) - needs to be pre-calculated externally
    SQRT_BAND_RATIO = _sqrt_band_ratio
    # log(A / (A - 1)) - needs to be pre-calculated externally
    LOG_A_RATIO = _log_A_ratio

    ADMIN = admin
    BORROWED_TOKEN.approve(ADMIN, max_value(uint256))
    COLLATERAL_TOKEN.approve(ADMIN, max_value(uint256))


# Low-level math
@internal
@pure
def sqrt_int(x: uint256) -> uint256:
    # https://github.com/transmissions11/solmate/blob/v7/src/utils/FixedPointMathLib.sol#L288
    _x: uint256 = x * 10**18
    y: uint256 = _x
    z: uint256 = 181
    if y >= 2**(128 + 8):
        y = unsafe_div(y, 2**128)
        z = unsafe_mul(z, 2**64)
    if y >= 2**(64 + 8):
        y = unsafe_div(y, 2**64)
        z = unsafe_mul(z, 2**32)
    if y >= 2**(32 + 8):
        y = unsafe_div(y, 2**32)
        z = unsafe_mul(z, 2**16)
    if y >= 2**(16 + 8):
        y = unsafe_div(y, 2**16)
        z = unsafe_mul(z, 2**8)

    z = unsafe_div(unsafe_mul(z, unsafe_add(y, 65536)), 2**18)

    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    z = unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
    return unsafe_div(unsafe_add(unsafe_div(_x, z), z), 2)
## End of low-level math


@external
@view
def collateral_token() -> address:
    return COLLATERAL_TOKEN.address


@external
@view
def A() -> uint256:
    return A


@external
@view
def price_oracle() -> uint256:
    return self.price_oracle_contract.price()


@internal
@view
def _rate_mul() -> uint256:
    return self.rate_mul + self.rate * (block.timestamp - self.rate_time)


@external
@view
def get_rate_mul() -> uint256:
    return self._rate_mul()


@internal
@view
def _base_price() -> uint256:
    """
    Base price grows with time to account for interest rate (which is 0 by default)
    """
    return unsafe_div(BASE_PRICE * self._rate_mul(), 10**18)


@external
@view
def get_base_price() -> uint256:
    return self._base_price()


@internal
@view
def _p_oracle_up(n: int256) -> uint256:
    # p_oracle_up(n) = p_base * ((A - 1) / A) ** n
    # p_oracle_down(n) = p_base * ((A - 1) / A) ** (n + 1) = p_oracle_up(n+1)
    # return unsafe_div(self._base_price() * self.exp_int(-n * LOG_A_RATIO), 10**18)

    power: int256 = -n * LOG_A_RATIO
    # exp(-n * LOG_A_RATIO)
    ## Exp implementation based on solmate's
    assert power > -42139678854452767551
    assert power < 135305999368893231589

    x: int256 = unsafe_div(unsafe_mul(power, 2**96), 10**18)

    k: int256 = unsafe_div(
        unsafe_add(
            unsafe_div(unsafe_mul(x, 2**96), 54916777467707473351141471128),
            2**95),
        2**96)
    x = unsafe_sub(x, unsafe_mul(k, 54916777467707473351141471128))

    y: int256 = unsafe_add(x, 1346386616545796478920950773328)
    y = unsafe_add(unsafe_div(unsafe_mul(y, x), 2**96), 57155421227552351082224309758442)
    p: int256 = unsafe_sub(unsafe_add(y, x), 94201549194550492254356042504812)
    p = unsafe_add(unsafe_div(unsafe_mul(p, y), 2**96), 28719021644029726153956944680412240)
    p = unsafe_add(unsafe_mul(p, x), (4385272521454847904659076985693276 * 2**96))

    q: int256 = x - 2855989394907223263936484059900
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 50020603652535783019961831881945)
    q = unsafe_sub(unsafe_div(unsafe_mul(q, x), 2**96), 533845033583426703283633433725380)
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 3604857256930695427073651918091429)
    q = unsafe_sub(unsafe_div(unsafe_mul(q, x), 2**96), 14423608567350463180887372962807573)
    q = unsafe_add(unsafe_div(unsafe_mul(q, x), 2**96), 26449188498355588339934803723976023)

    exp_result: uint256 = shift(
        unsafe_mul(convert(unsafe_div(p, q), uint256), 3822833074963236453042738258902158003155416615667),
        unsafe_sub(k, 195))
    ## End exp
    return unsafe_div(self._base_price() * exp_result, 10**18)


@internal
@view
def _p_current_band(n: int256) -> uint256:
    """
    Upper or lower price of the band `n` at current `p_oracle`
    """
    # k = (self.A - 1) / self.A  # equal to (p_up / p_down)
    # p_base = self.p_base * k ** (n_band + 1)
    p_base: uint256 = self._p_oracle_up(n)

    # return self.p_oracle**3 / p_base**2
    p_oracle: uint256 = self.price_oracle_contract.price()
    return unsafe_div(p_oracle**2 / p_base * p_oracle, p_base)


@external
@view
def p_current_up(n: int256) -> uint256:
    """
    Upper price of the band `n` at current `p_oracle`
    """
    return self._p_current_band(n + 1)


@external
@view
def p_current_down(n: int256) -> uint256:
    """
    Lower price of the band `n` at current `p_oracle`
    """
    return self._p_current_band(n)


@external
@view
def p_oracle_up(n: int256) -> uint256:
    """
    Upper price of the band `n` when `p_oracle` == `p`
    """
    return self._p_oracle_up(n)


@external
@view
def p_oracle_down(n: int256) -> uint256:
    """
    Lower price of the band `n` when `p_oracle` == `p`
    """
    return self._p_oracle_up(n + 1)


@internal
@view
def _get_y0(x: uint256, y: uint256, p_o: uint256, p_o_up: uint256) -> uint256:
    assert p_o != 0
    # solve:
    # p_o * A * y0**2 - y0 * (p_oracle_up/p_o * (A-1) * x + p_o**2/p_oracle_up * A * y) - xy = 0
    b: uint256 = 0
    # p_o_up * unsafe_sub(A, 1) * x / p_o + A * p_o**2 / p_o_up * y / 10**18
    if x != 0:
        b = unsafe_div(p_o_up * Aminus1 * x, p_o)
    if y != 0:
        b += unsafe_div(A * p_o**2 / p_o_up * y, 10**18)
    if x > 0 and y > 0:
        D: uint256 = b**2 + unsafe_div(((4 * A) * p_o) * y, 10**18) * x
        return unsafe_div((b + self.sqrt_int(unsafe_div(D, 10**18))) * 10**18, unsafe_mul(2 * A, p_o))
    else:
        return unsafe_div(b * 10**18, A * p_o)


@external
@view
def get_y0(_n: int256) -> uint256:
    n: int256 = _n
    if _n == max_value(int256):
        n = self.active_band
    return self._get_y0(
        self.bands_x[n],
        self.bands_y[n],
        self.price_oracle_contract.price(),
        self._p_oracle_up(n)
    )


@internal
@view
def _get_p(n: int256, x: uint256, y: uint256) -> uint256:
    p_o_up: uint256 = self._p_oracle_up(n)
    p_o: uint256 = self.price_oracle_contract.price()

    # Special cases
    if x == 0:
        if y == 0:  # x and y are 0
            p_o_up = unsafe_div(p_o_up * Aminus1, A)
            return unsafe_div(unsafe_div(p_o**2 / p_o_up * p_o, p_o_up) * 10**18, SQRT_BAND_RATIO)
        # if x == 0: # Lowest point of this band -> p_current_down
        return unsafe_div(p_o**2 / p_o_up * p_o, p_o_up)
    if y == 0: # Highest point of this band -> p_current_up
        p_o_up = unsafe_div(p_o_up * Aminus1, A)
        return unsafe_div(p_o**2 / p_o_up * p_o, p_o_up)

    y0: uint256 = self._get_y0(x, y, p_o, p_o_up)
    # ^ that call also checks that p_o != 0

    # (f(y0) + x) / (g(y0) + y)
    f: uint256 = A * y0 * p_o / p_o_up * p_o
    g: uint256 = unsafe_div(Aminus1 * y0 * p_o_up, p_o)
    return (f + x * 10**18) / (g + y)


@external
@view
def get_p() -> uint256:
    n: int256 = self.active_band
    return self._get_p(n, self.bands_x[n], self.bands_y[n])


@internal
@view
def _read_user_tick_numbers(user: address) -> int256[2]:
    """
    Unpacks and reads user tick numbers
    """
    ns: int256 = self.user_shares[user].ns
    n2: int256 = unsafe_div(ns, 2**128)
    n1: int256 = ns % 2**128
    if n1 >= 2**127:
        n1 = unsafe_sub(n1, 2**128)
        n2 = unsafe_add(n2, 1)
    return [n1, n2]


@external
@view
def read_user_tick_numbers(user: address) -> int256[2]:
    return self._read_user_tick_numbers(user)


@internal
@view
def _read_user_ticks(user: address, size: int256) -> uint256[MAX_TICKS]:
    """
    Unpacks and reads user ticks
    """
    ticks: uint256[MAX_TICKS] = empty(uint256[MAX_TICKS])
    ptr: int256 = 0
    for i in range(MAX_TICKS / 2):
        if unsafe_add(ptr, 1) > size:
            break
        tick: uint256 = self.user_shares[user].ticks[i]
        ticks[ptr] = tick & (2**128 - 1)
        ptr += 1
        if ptr != size:
            ticks[ptr] = shift(tick, -128)
        ptr += 1
    return ticks


@internal
@view
def _can_skip_bands(n_end: int256) -> bool:
    n: int256 = self.active_band
    for i in range(MAX_SKIP_TICKS):
        if n_end > n:
            if self.bands_y[n] != 0:
                return False
            n = unsafe_add(n, 1)
        else:
            if self.bands_x[n] != 0:
                return False
            n = unsafe_sub(n, 1)
        if n == n_end:  # not including n_end
            break
    return True


@external
@view
def can_skip_bands(n_end: int256) -> bool:
    return self._can_skip_bands(n_end)
    # Actually skipping bands:
    # * change self.active_band to the new n
    # * change self.p_base_mul
    # to do n2-n1 times (if n2 > n1):
    # out.base_mul = unsafe_div(out.base_mul * Aminus1, A)


@external
@nonreentrant('lock')
def deposit_range(user: address, amount: uint256, n1: int256, n2: int256, move_coins: bool):
    assert msg.sender == ADMIN

    n0: int256 = self.active_band
    band: int256 = max(n1, n2)  # Fill from high N to low N
    upper: int256 = band
    lower: int256 = min(n1, n2)
    assert upper < 2**127
    assert lower >= -2**127

    # Autoskip bands if we can
    for i in range(MAX_SKIP_TICKS + 1):
        if lower > n0:
            if i != 0:
                self.active_band = n0
            break
        assert self.bands_x[n0] == 0 and i < MAX_SKIP_TICKS, "Deposit below current band"
        n0 -= 1

    if move_coins:
        assert COLLATERAL_TOKEN.transferFrom(user, self, amount)

    i: uint256 = convert(unsafe_sub(band, lower), uint256)
    n_bands: uint256 = unsafe_add(i, 1)

    y: uint256 = unsafe_div(amount * COLLATERAL_PRECISION, n_bands)
    assert y > 100, "Amount too low"

    save_n: bool = True
    if self.user_shares[user].ticks[0] != 0:  # Has liquidity
        ns: int256[2] = self._read_user_tick_numbers(user)
        assert ns[0] == lower and ns[1] == band, "Wrong range"
        save_n = False

    user_shares: uint256[MAX_TICKS] = empty(uint256[MAX_TICKS])

    for j in range(MAX_TICKS):
        if i == 0:
            # Take the dust in the last band
            # Maybe could give up on this though
            y = amount * COLLATERAL_PRECISION - y * unsafe_sub(n_bands, 1)
        # Deposit coins
        assert self.bands_x[band] == 0, "Band not empty"
        total_y: uint256 = self.bands_y[band]
        self.bands_y[band] = total_y + y
        # Total / user share
        s: uint256 = self.total_shares[band]
        if s == 0:
            assert y < 2**128
            s = y
            user_shares[i] = y
        else:
            ds: uint256 = s * y / total_y
            assert ds > 0, "Amount too low"
            user_shares[i] = ds
            s += ds
        self.total_shares[band] = s
        # End the cycle
        band -= 1
        if i == 0:
            break
        i -= 1

    self.min_band = min(self.min_band, lower)
    self.max_band = max(self.max_band, upper)

    if save_n:
        self.user_shares[user].ns = lower + upper * 2**128

    dist: uint256 = convert(unsafe_sub(upper, lower), uint256) + 1
    ptr: uint256 = 0
    for j in range(MAX_TICKS_UINT / 2):
        if ptr >= dist:
            break
        tick: uint256 = user_shares[ptr]
        ptr += 1
        if dist != ptr:
            tick = tick | shift(user_shares[ptr], 128)
        ptr += 1
        self.user_shares[user].ticks[j] = tick

    self.rate_mul = self._rate_mul()
    self.rate_time = block.timestamp

    log Deposit(user, amount, n1, n2)


@external
@nonreentrant('lock')
def withdraw(user: address, move_to: address) -> uint256[2]:
    assert msg.sender == ADMIN

    ns: int256[2] = self._read_user_tick_numbers(user)
    user_shares: uint256[MAX_TICKS] = self._read_user_ticks(user, ns[1] - ns[0] + 1)
    assert user_shares[0] > 0, "No deposits"

    total_x: uint256 = 0
    total_y: uint256 = 0
    min_band: int256 = self.min_band
    old_min_band: int256 = min_band
    max_band: int256 = 0

    for i in range(MAX_TICKS):
        x: uint256 = self.bands_x[ns[0]]
        y: uint256 = self.bands_y[ns[0]]
        ds: uint256 = user_shares[i]
        s: uint256 = self.total_shares[ns[0]]
        dx: uint256 = x * ds / s
        dy: uint256 = unsafe_div(y * ds, s)

        self.total_shares[ns[0]] = s - ds
        x -= dx
        y -= dy
        if ns[0] == min_band:
            if x == 0:
                if y == 0:
                    min_band += 1
        if x > 0 or y > 0:
            max_band = ns[0]
        self.bands_x[ns[0]] = x
        self.bands_y[ns[0]] = y
        total_x += dx
        total_y += dy

        ns[0] += 1
        if ns[0] > ns[1]:
            break

    # Empty the ticks
    self.user_shares[user].ticks[0] = 0

    if old_min_band != min_band:
        self.min_band = min_band
    if self.max_band <= ns[1]:
        self.max_band = max_band

    total_x = unsafe_div(total_x, BORROWED_PRECISION)
    total_y = unsafe_div(total_y, COLLATERAL_PRECISION)
    if move_to != empty(address):
        assert BORROWED_TOKEN.transfer(move_to, total_x)
        assert COLLATERAL_TOKEN.transfer(move_to, total_y)
    log Withdraw(user, move_to, total_x, total_y)

    self.rate_mul = self._rate_mul()
    self.rate_time = block.timestamp

    return [total_x, total_y]


@internal
@view
def calc_swap_out(pump: bool, in_amount: uint256, p_o: uint256) -> DetailedTrade:
    # pump = True: borrowable (USD) in, collateral (ETH) out; going up
    # pump = False: collateral (ETH) in, borrowable (USD) out; going down
    min_band: int256 = self.min_band
    max_band: int256 = self.max_band
    out: DetailedTrade = empty(DetailedTrade)
    out.n2 = self.active_band
    p_o_up: uint256 = self._p_oracle_up(out.n2)
    base_price: uint256 = self._base_price()
    x: uint256 = self.bands_x[out.n2]
    y: uint256 = self.bands_y[out.n2]

    fee: uint256 = self.fee
    admin_fee: uint256 = self.admin_fee
    in_amount_afee: uint256 = unsafe_div(unsafe_div(in_amount * fee, 10**18) * admin_fee, 10**18)
    in_amount_left: uint256 = unsafe_sub(in_amount, in_amount_afee)
    in_amount_used: uint256 = 0
    fee = (10**18)**2 / unsafe_sub(10**18, fee)
    j: uint256 = MAX_TICKS_UINT

    for i in range(MAX_TICKS + MAX_SKIP_TICKS):
        y0: uint256 = 0
        f: uint256 = 0
        g: uint256 = 0
        Inv: uint256 = 0

        if x > 0 or y > 0:
            if j == MAX_TICKS_UINT:
                out.n1 = out.n2
                j = 0
            y0 = self._get_y0(x, y, p_o, p_o_up)  # <- also checks p_o
            f = unsafe_div(A * y0 * p_o / p_o_up * p_o, 10**18)
            g = unsafe_div(Aminus1 * y0 * p_o_up, p_o)
            Inv = (f + x) * (g + y)

        if pump:
            if y != 0:
                if g != 0:
                    x_dest: uint256 = unsafe_div(Inv, g) - f
                    if unsafe_div((x_dest - x) * fee, 10**18) >= in_amount_left:
                        # This is the last band
                        out.last_tick_j = Inv / (f + (x + in_amount_left * 10**18 / fee)) - g  # Should be always >= 0
                        x += in_amount_left  # x is precise after this
                        # Round down the output
                        out.out_amount += unsafe_mul(unsafe_div(y - out.last_tick_j, COLLATERAL_PRECISION), COLLATERAL_PRECISION)
                        out.ticks_in[j] = x
                        out.in_amount = in_amount
                        return out

                    else:
                        # We go into the next band
                        dx: uint256 = unsafe_div((x_dest - x) * fee, 10**18)
                        in_amount_left -= dx
                        out.ticks_in[j] = x + dx
                        in_amount_used += dx
                        out.out_amount += y

            if i != MAX_TICKS + MAX_SKIP_TICKS - 1:
                if out.n2 == max_band:
                    break
                if j == MAX_TICKS_UINT - 1:
                    break
                out.n2 += 1
                p_o_up = unsafe_div(p_o_up * Aminus1, A)
                x = 0
                y = self.bands_y[out.n2]

        else:  # dump
            if x != 0:
                if f != 0:
                    y_dest: uint256 = unsafe_div(Inv, f) - g
                    if unsafe_div((y_dest - y) * fee, 10**18) >= in_amount_left:
                        # This is the last band
                        out.last_tick_j = Inv / (g + (y + in_amount_left * 10**18 / fee)) - f
                        y += in_amount_left
                        out.out_amount += unsafe_mul(unsafe_div(x - out.last_tick_j, BORROWED_PRECISION), BORROWED_PRECISION)
                        out.ticks_in[j] = y
                        out.in_amount = in_amount
                        return out

                    else:
                        # We go into the next band
                        dy: uint256 = unsafe_div((y_dest - y) * fee, 10**18)
                        in_amount_left -= dy
                        out.ticks_in[j] = y + dy
                        in_amount_used += dy
                        out.out_amount += x

            if i != MAX_TICKS + MAX_SKIP_TICKS - 1:
                if out.n2 == min_band:
                    break
                if j == MAX_TICKS_UINT - 1:
                    break
                out.n2 -= 1
                p_o_up = unsafe_div(p_o_up * A, Aminus1)
                x = self.bands_x[out.n2]
                y = 0

        if j != MAX_TICKS_UINT:
            j = unsafe_add(j, 1)

    # Round up what goes in and down what goes out
    out.in_amount = in_amount_used + in_amount_afee
    if pump:
        in_amount_used = unsafe_mul(unsafe_div(in_amount_used, BORROWED_PRECISION), BORROWED_PRECISION)
        if in_amount_used != out.in_amount:
            out.in_amount = in_amount_used + BORROWED_PRECISION
        out.out_amount = unsafe_mul(unsafe_div(out.out_amount, COLLATERAL_PRECISION), COLLATERAL_PRECISION)
    else:
        in_amount_used = unsafe_mul(unsafe_div(in_amount_used, COLLATERAL_PRECISION), COLLATERAL_PRECISION)
        if in_amount_used != out.in_amount:
            out.in_amount = in_amount_used + COLLATERAL_PRECISION
        out.out_amount = unsafe_mul(unsafe_div(out.out_amount, BORROWED_PRECISION), BORROWED_PRECISION)
    return out


@internal
@view
def _get_dxdy(i: uint256, j: uint256, in_amount: uint256) -> DetailedTrade:
    """
    Method to be used to figure if we have some in_amount left or not
    """
    assert (i == 0 and j == 1) or (i == 1 and j == 0), "Wrong index"
    out: DetailedTrade = empty(DetailedTrade)
    if in_amount == 0:
        return out
    in_precision: uint256 = COLLATERAL_PRECISION
    out_precision: uint256 = BORROWED_PRECISION
    if i == 0:
        in_precision = BORROWED_PRECISION
        out_precision = COLLATERAL_PRECISION
    out = self.calc_swap_out(i == 0, in_amount * in_precision, self.price_oracle_contract.price())
    out.in_amount = unsafe_div(out.in_amount, in_precision)
    out.out_amount = unsafe_div(out.out_amount, out_precision)
    return out


@external
@view
def get_dy(i: uint256, j: uint256, in_amount: uint256) -> uint256:
    return self._get_dxdy(i, j, in_amount).out_amount


@external
@view
def get_dxdy(i: uint256, j: uint256, in_amount: uint256) -> (uint256, uint256):
    """
    Method to be used to figure if we have some in_amount left or not
    """
    out: DetailedTrade = self._get_dxdy(i, j, in_amount)
    return (out.in_amount, out.out_amount)


# Unused
# @external
# @view
# def get_end_price(i: uint256, j: uint256, in_amount: uint256) -> uint256:
#     out: DetailedTrade = self._get_dxdy(i, j, in_amount)
#     x: uint256 = 0
#     y: uint256 = 0
#     if i == 0:  # pump
#         x = out.ticks_in[abs(out.n2 - out.n1)]
#         y = out.last_tick_j
#     else:  # dump
#         x = out.last_tick_j
#         y = out.ticks_in[abs(out.n2 - out.n1)]
#     return self._get_p(out.n2, x, y)


@external
@nonreentrant('lock')
def exchange(i: uint256, j: uint256, in_amount: uint256, min_amount: uint256, _for: address = msg.sender) -> uint256:
    assert (i == 0 and j == 1) or (i == 1 and j == 0), "Wrong index"
    if in_amount == 0:
        return 0

    in_coin: ERC20 = BORROWED_TOKEN
    out_coin: ERC20 = COLLATERAL_TOKEN
    in_precision: uint256 = BORROWED_PRECISION
    out_precision: uint256 = COLLATERAL_PRECISION
    if i == 1:
        in_precision = out_precision
        in_coin = out_coin
        out_precision = BORROWED_PRECISION
        out_coin = BORROWED_TOKEN

    out: DetailedTrade = self.calc_swap_out(i == 0, in_amount * in_precision, self.price_oracle_contract.price_w())
    in_amount_done: uint256 = unsafe_div(out.in_amount, in_precision)
    out_amount_done: uint256 = unsafe_div(out.out_amount, out_precision)
    assert out_amount_done >= min_amount, "Slippage"
    if out_amount_done == 0:
        return 0

    in_coin.transferFrom(msg.sender, self, in_amount_done)
    out_coin.transfer(_for, out_amount_done)

    n: int256 = out.n1
    step: int256 = 1
    if out.n2 < out.n1:
        step = -1
    for k in range(MAX_TICKS):
        if i == 0:
            self.bands_x[n] = out.ticks_in[k]
            if n == out.n2:
                self.bands_y[n] = out.last_tick_j
                break
            self.bands_y[n] = 0

        else:
            self.bands_y[n] = out.ticks_in[k]
            if n == out.n2:
                self.bands_x[n] = out.last_tick_j
                break
            self.bands_x[n] = 0

        n += step

    self.active_band = n

    log TokenExchange(_for, i, in_amount_done, j, out_amount_done)

    return out_amount_done


@internal
@view
def get_xy_up(user: address, use_y: bool) -> uint256:
    """
    Measure the amount of y in the band n if we adiabatically trade near p_oracle on the way up
    """
    ns: int256[2] = self._read_user_tick_numbers(user)
    ticks: uint256[MAX_TICKS] = self._read_user_ticks(user, ns[1] - ns[0] + 1)
    if ticks[0] == 0:
        return 0
    p_o: uint256 = self.price_oracle_contract.price()
    assert p_o != 0

    n: int256 = ns[0] - 1
    n_active: int256 = self.active_band
    p_o_down: uint256 = self._p_oracle_up(n + 1)
    XY: uint256 = 0

    for i in range(MAX_TICKS):
        n += 1
        if n > ns[1]:
            break
        x: uint256 = 0
        y: uint256 = 0
        if n >= n_active:
            y = self.bands_y[n]
        if n <= n_active:
            x = self.bands_x[n]
        p_o_up: uint256 = p_o_down
        p_o_down = unsafe_div(p_o_down * Aminus1, A)
        if x == 0:
            if y == 0:
                continue

        total_share: uint256 = self.total_shares[n]
        user_share: uint256 = ticks[i]
        if total_share == 0:
            continue
        if user_share == 0:
            continue

        # Also this will revert if p_o_down is 0, and p_o_down is 0 if p_o_up is 0
        p_current_mid: uint256 = unsafe_div(unsafe_div(p_o**2 / p_o_down * p_o, p_o_down) * Aminus1, A)

        # if p_o > p_o_up - we "trade" everything to y and then convert to the result
        # if p_o < p_o_down - "trade" to x, then convert to result
        # otherwise we are in-band, so we do the more complex logic to trade
        # to p_o rather than to the edge of the band
        # trade to the edge of the band == getting to the band edge while p_o=const

        # Cases when special conversion is not needed (to save on computations)
        if x == 0 or y == 0:
            if p_o > p_o_up:  # p_o < p_current_down
                # all to y at constant p_o, then to target currency adiabatically
                y_equiv: uint256 = y
                if y == 0:
                    y_equiv = x * 10**18 / p_current_mid
                if use_y:
                    XY += unsafe_div(y_equiv * user_share, total_share)
                else:
                    XY += unsafe_div(unsafe_div(y_equiv * p_o_up, SQRT_BAND_RATIO) * user_share, total_share)
                continue

            elif p_o < p_o_down:  # p_o > p_current_up
                # all to x at constant p_o, then to target currency adiabatically
                x_equiv: uint256 = x
                if x == 0:
                    x_equiv = unsafe_div(y * p_current_mid, 10**18)
                if use_y:
                    XY += unsafe_div(unsafe_div(x_equiv * SQRT_BAND_RATIO, p_o_up) * user_share, total_share)
                else:
                    XY += unsafe_div(x_equiv * user_share, total_share)
                continue

        # If we are here - we need to "trade" to somewhere mid-band
        # So we need more heavy math

        y0: uint256 = self._get_y0(x, y, p_o, p_o_up)
        f: uint256 = unsafe_div(unsafe_div(A * y0 * p_o, p_o_up) * p_o, 10**18)
        g: uint256 = unsafe_div(Aminus1 * y0 * p_o_up, p_o)
        # (f + x)(g + y) = const = p_top * A**2 * y0**2 = I
        Inv: uint256 = (f + x) * (g + y)
        # p = (f + x) / (g + y) => p * (g + y)**2 = I or (f + x)**2 / p = I

        # First, "trade" in this band to p_oracle
        x_o: uint256 = 0
        y_o: uint256 = 0

        if p_o > p_o_up:  # p_o < p_current_down, all to y
            # x_o = 0
            y_o = unsafe_sub(max(Inv / f, g), g)
            if use_y:
                XY += unsafe_div(y_o * user_share, total_share)
            else:
                XY += unsafe_div(unsafe_div(y_o * p_o_up, SQRT_BAND_RATIO) * user_share, total_share)

        elif p_o < p_o_down:  # p_o > p_current_up, all to x
            # y_o = 0
            x_o = unsafe_sub(max(Inv / g, f), f)
            if use_y:
                XY += unsafe_div(unsafe_div(x_o * SQRT_BAND_RATIO, p_o_up) * user_share, total_share)
            else:
                XY += unsafe_div(x_o * user_share, total_share)

        else:
            y_o = unsafe_sub(max(self.sqrt_int(unsafe_div(Inv, p_o)), g), g)
            x_o = unsafe_sub(max(Inv / (g + y_o), f), f)
            # Now adiabatic conversion from definitely in-band
            if use_y:
                XY += unsafe_div((y_o + x_o * 10**18 / self.sqrt_int(unsafe_div(p_o_up * p_o, 10**18))) * user_share, total_share)

            else:
                XY += unsafe_div((x_o + unsafe_div(y_o * self.sqrt_int(unsafe_div(p_o_down * p_o, 10**18)), 10**18)) * user_share, total_share)

    if use_y:
        return unsafe_div(XY, COLLATERAL_PRECISION)
    else:
        return unsafe_div(XY, BORROWED_PRECISION)


@external
@view
def get_y_up(user: address) -> uint256:
    return self.get_xy_up(user, True)


@external
@view
def get_x_down(user: address) -> uint256:
    return self.get_xy_up(user, False)


@external
@view
def get_sum_xy(user: address) -> uint256[2]:
    x: uint256 = 0
    y: uint256 = 0
    ns: int256[2] = self._read_user_tick_numbers(user)
    ticks: uint256[MAX_TICKS] = self._read_user_ticks(user, ns[1] - ns[0] + 1)
    for i in range(MAX_TICKS):
        total_shares: uint256 = self.total_shares[ns[0]]
        x += self.bands_x[ns[0]] * ticks[i] / total_shares
        y += unsafe_div(self.bands_y[ns[0]] * ticks[i], total_shares)
        if ns[0] == ns[1]:
            break
        ns[0] += 1
    return [unsafe_div(x, BORROWED_PRECISION), unsafe_div(y, COLLATERAL_PRECISION)]


@external
@view
def get_amount_for_price(p: uint256) -> (uint256, bool):
    """
    Amount necessary to be exchange to have the AMM at the final price p
    :returns: amount, is_pump
    """
    min_band: int256 = self.min_band
    max_band: int256 = self.max_band
    n: int256 = self.active_band
    p_o: uint256 = self.price_oracle_contract.price()
    p_o_up: uint256 = self._p_oracle_up(n)
    p_down: uint256 = unsafe_div(p_o**2 / p_o_up * p_o, p_o_up)  # p_current_down
    p_up: uint256 = unsafe_div(p_down * A2, Aminus12)  # p_crurrent_up
    amount: uint256 = 0
    y0: uint256 = 0
    f: uint256 = 0
    g: uint256 = 0
    Inv: uint256 = 0
    j: uint256 = MAX_TICKS_UINT
    pump: bool = True

    for i in range(MAX_TICKS + MAX_SKIP_TICKS):
        x: uint256 = self.bands_x[n]
        y: uint256 = self.bands_y[n]
        if i == 0:
            if p < self._get_p(n, x, y):
                pump = False
        not_empty: bool = x > 0 or y > 0
        if not_empty:
            y0 = self._get_y0(x, y, p_o, p_o_up)
            f = unsafe_div(A * y0 * p_o / p_o_up * p_o, 10**18)
            g = unsafe_div(Aminus1 * y0 * p_o_up, p_o)
            Inv = (f + x) * (g + y)
            if j == MAX_TICKS_UINT:
                j = 0

        if p <= p_up:
            if p >= p_down:
                if not_empty:
                    ynew: uint256 = unsafe_sub(max(self.sqrt_int(Inv / p), g), g)
                    xnew: uint256 = unsafe_sub(max(Inv / (g + ynew), f), f)
                    if pump:
                        amount += unsafe_sub(max(xnew, x), x)
                    else:
                        amount += unsafe_sub(max(ynew, y), y)
                break

        if pump:
            if not_empty:
                amount += (Inv / g - f) - x
            if n == max_band:
                break
            if j == MAX_TICKS_UINT - 1:
                break
            n += 1
            p_down = p_up
            p_up = unsafe_div(p_up * A2, Aminus12)
            p_o_up = unsafe_div(p_o_up * Aminus1, A)

        else:
            if not_empty:
                amount += (Inv / f - g) - y
            if n == min_band:
                break
            if j == MAX_TICKS_UINT - 1:
                break
            n -= 1
            p_up = p_down
            p_down = unsafe_div(p_down * Aminus12, A2)
            p_o_up = unsafe_div(p_o_up * A, Aminus1)

        if j != MAX_TICKS_UINT:
            j = unsafe_add(j, 1)

    amount = amount * 10**18 / unsafe_sub(10**18, self.fee)
    if amount == 0:
        return 0, pump

    # Precision and round up
    if pump:
        amount = unsafe_add(unsafe_div(unsafe_sub(amount, 1), BORROWED_PRECISION), 1)
    else:
        amount = unsafe_add(unsafe_div(unsafe_sub(amount, 1), COLLATERAL_PRECISION), 1)

    return amount, pump


@external
def set_rate(rate: uint256) -> uint256:
    assert msg.sender == ADMIN
    rate_mul: uint256 = self._rate_mul()
    self.rate_mul = rate_mul
    self.rate_time = block.timestamp
    self.rate = rate
    log SetRate(rate, rate_mul, block.timestamp)
    return rate_mul


@external
def set_fee(fee: uint256):
    assert msg.sender == ADMIN
    assert fee < MAX_FEE, "High fee"
    self.fee = fee
    log SetFee(fee)


@external
def set_admin_fee(fee: uint256):
    assert msg.sender == ADMIN
    assert fee < MAX_ADMIN_FEE, "High fee"
    self.admin_fee = fee
    log SetAdminFee(fee)

@external
def set_price_oracle(price_oracle: address):
    assert msg.sender == ADMIN
    assert PriceOracle(price_oracle).price_w() > 0
    assert PriceOracle(price_oracle).price() > 0
    self.price_oracle_contract = PriceOracle(price_oracle)
    log SetPriceOracle(price_oracle)
