import argparse
import random
from pathlib import Path

CANONICAL_QNAN = 0x7FF8000000000000
STATUS_INVALID = 1 << 4
STATUS_OVERFLOW = 1 << 3
STATUS_UNDERFLOW = 1 << 2
STATUS_INEXACT = 1 << 1


def classify(bits: int):
    sign = (bits >> 63) & 1
    exp = (bits >> 52) & 0x7FF
    frac = bits & ((1 << 52) - 1)

    if exp == 0x7FF:
        if frac != 0:
            return {"kind": "nan", "sign": sign}
        return {"kind": "inf", "sign": sign}

    if exp == 0:
        if frac == 0:
            return {"kind": "zero", "sign": sign}
        return {"kind": "finite", "sign": sign, "mant": frac, "e": -1074}

    return {"kind": "finite", "sign": sign, "mant": (1 << 52) | frac, "e": exp - 1075}


def round_shifted_int(value: int, shift: int):
    if shift <= 0:
        return value << (-shift), False

    q = value >> shift
    rem = value & ((1 << shift) - 1)
    if rem == 0:
        return q, False

    half = 1 << (shift - 1)
    increment = rem > half or (rem == half and (q & 1))
    return q + (1 if increment else 0), True


def pack_exact_sum(sum_int: int, base_exp: int, zero_sign: int):
    if sum_int == 0:
        return (zero_sign << 63), 0

    sign = 1 if sum_int < 0 else 0
    abs_n = -sum_int if sum_int < 0 else sum_int
    bit_len = abs_n.bit_length()
    unbiased_exp = base_exp + bit_len - 1

    if unbiased_exp >= -1022:
        shift = bit_len - 53
        sig53, inexact = round_shifted_int(abs_n, shift)
        unbiased_exp = base_exp + bit_len - 1

        if sig53 >= (1 << 53):
            sig53 >>= 1
            unbiased_exp += 1

        if unbiased_exp > 1023:
            return ((sign << 63) | (0x7FF << 52), STATUS_OVERFLOW | STATUS_INEXACT)

        if unbiased_exp >= -1022:
            exp_field = unbiased_exp + 1023
            frac = sig53 & ((1 << 52) - 1)
            status = STATUS_INEXACT if inexact else 0
            return ((sign << 63) | (exp_field << 52) | frac, status)

    sub_shift = -(base_exp + 1074)
    frac52, inexact = round_shifted_int(abs_n, sub_shift)

    if frac52 >= (1 << 52):
        bits = (sign << 63) | (1 << 52)
        status = (STATUS_UNDERFLOW | STATUS_INEXACT) if inexact else 0
        return bits, status

    bits = (sign << 63) | frac52
    status = (STATUS_UNDERFLOW | STATUS_INEXACT) if inexact else 0
    return bits, status


def reference_add(a_bits: int, b_bits: int):
    a = classify(a_bits)
    b = classify(b_bits)

    if a["kind"] == "nan" or b["kind"] == "nan":
        return CANONICAL_QNAN, 0

    if a["kind"] == "inf" and b["kind"] == "inf" and a["sign"] != b["sign"]:
        return CANONICAL_QNAN, STATUS_INVALID
    if a["kind"] == "inf":
        return ((a["sign"] << 63) | (0x7FF << 52)), 0
    if b["kind"] == "inf":
        return ((b["sign"] << 63) | (0x7FF << 52)), 0

    if a["kind"] == "zero" and b["kind"] == "zero":
        return ((a["sign"] & b["sign"]) << 63), 0
    if a["kind"] == "zero":
        return b_bits, 0
    if b["kind"] == "zero":
        return a_bits, 0

    common_e = min(a["e"], b["e"])
    a_term = a["mant"] << (a["e"] - common_e)
    b_term = b["mant"] << (b["e"] - common_e)
    if a["sign"]:
        a_term = -a_term
    if b["sign"]:
        b_term = -b_term

    sum_int = a_term + b_term
    return pack_exact_sum(sum_int, common_e, 0)


def random_bits(rng: random.Random):
    category = rng.randrange(10)
    if category == 0:
        return 0x7FF0000000000000 if rng.randrange(2) == 0 else 0xFFF0000000000000
    if category == 1:
        payload = rng.getrandbits(52) or 1
        sign = rng.randrange(2) << 63
        return sign | (0x7FF << 52) | payload
    if category == 2:
        sign = rng.randrange(2) << 63
        frac = rng.getrandbits(52) or 1
        return sign | frac
    if category == 3:
        sign = rng.randrange(2) << 63
        exp = 1 + rng.randrange(3)
        frac = rng.getrandbits(52)
        return sign | (exp << 52) | frac
    if category == 4:
        sign = rng.randrange(2) << 63
        exp = 0x7FD + rng.randrange(2)
        frac = rng.getrandbits(52)
        return sign | (exp << 52) | frac
    if category == 5:
        sign = rng.randrange(2) << 63
        exp = rng.randrange(0x001, 0x7FE)
        frac = rng.getrandbits(52)
        return sign | (exp << 52) | frac
    if category == 6:
        return 0x0000000000000000 if rng.randrange(2) == 0 else 0x8000000000000000
    if category == 7:
        return 0x3FF0000000000000
    if category == 8:
        return 0xBFF0000000000000
    return rng.getrandbits(64)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=20260318)
    parser.add_argument("--out-dir", type=Path, default=Path("frame_work.srcs/sim_1/data/fp64_add_random"))
    args = parser.parse_args()

    rng = random.Random(args.seed)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    a_lines = []
    b_lines = []
    result_lines = []
    status_lines = []

    for _ in range(args.count):
        a_bits = random_bits(rng)
        b_bits = random_bits(rng)
        result_bits, status = reference_add(a_bits, b_bits)
        a_lines.append(f"{a_bits:016x}")
        b_lines.append(f"{b_bits:016x}")
        result_lines.append(f"{result_bits:016x}")
        status_lines.append(f"{status:02x}")

    (args.out_dir / "a_bits.hex").write_text("\n".join(a_lines) + "\n", encoding="ascii")
    (args.out_dir / "b_bits.hex").write_text("\n".join(b_lines) + "\n", encoding="ascii")
    (args.out_dir / "result_bits.hex").write_text("\n".join(result_lines) + "\n", encoding="ascii")
    (args.out_dir / "status_bits.hex").write_text("\n".join(status_lines) + "\n", encoding="ascii")

    print(f"Generated {args.count} FP64 add vectors in {args.out_dir}")


if __name__ == "__main__":
    main()

