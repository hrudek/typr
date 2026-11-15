"""Convert FUTO Swipe's encoder into Typr's `swipe-encoder.tse`.

Source model: https://huggingface.co/futo-org/futo-swipe, revision
0a9a44bbe4d5b8aa8d1ff579ffc40d4861ae2467, file honorable_sturgeon/model_fp32.pte
(FUTO Model Weights License 1.0, see SwipeModel/LICENSE-FUTO-SWIPE.txt).
Only the encoder is converted: the English/QWERTY decoder (magic_macaw) lowered
German accuracy in Typr's evaluation and is not shipped.

The constant readers are adapted from iikb scripts/swipe.py (MIT, (c) 2026 Bassim
Shahidy), https://github.com/AVGVSTVS96/iikb at f42bad59ce3c0f6f35c7ec0cf727d0b67c146608.

Output layout (read in place by SwipeEncoder.swift): "TSE1", the number of floats as
a little-endian u32, 8 zero bytes, then the float32 tensors of ENTRIES in order. A
matrix is stored input-major with its outputs zero-padded to a multiple of 8; a
vector is zero-padded the same way.

Usage (downloaded model files are untrusted; run with -I):
  uv run --no-project --python 3.12 --with executorch --with numpy --with torch \
    python3 -I ios/tools/swipe_model/build.py <model_fp32.pte> <out.tse>
"""

import hashlib
import re
import struct
import sys

import numpy as np

ENCODER_SHA256 = "725242bab5d14345e96ff214e8de2bfbc1f962c232d320df9c24cb82ffd1fbaf"
HIDDEN, WIDE, KERNEL, BLOCKS, COEFFICIENTS = 128, 256, 7, 5, 64


def entries():
    out = []
    for name in ["d1_x", "d1_y", "d2_x", "d2_y", "d1_curv"]:
        out.append((f"encoder.savgol_{name}_weight", [1, KERNEL, 1], False))
    out.append(("encoder.backbone_input_conv_weight", [HIDDEN, KERNEL, 8], True))
    out.append(("encoder.backbone_input_conv_bias", [HIDDEN], False))
    for b in range(BLOCKS):
        p = f"encoder.backbone_blocks_{b}_"
        out += [
            (p + "dwconv_weight", [1, KERNEL, HIDDEN], False),
            (p + "dwconv_bias", [HIDDEN], False),
            (p + "pwconv1_weight", [4 * HIDDEN, 1, HIDDEN], True),
            (p + "pwconv1_bias", [4 * HIDDEN], False),
            (p + "grn_gamma", [WIDE], False),
            (p + "grn_beta", [WIDE], False),
            (p + "pwconv2_weight", [HIDDEN, 1, WIDE], True),
            (p + "pwconv2_bias", [HIDDEN], False),
            (p + "se_fc1_weight", [HIDDEN // 4, HIDDEN], True),
            (p + "se_fc1_bias", [HIDDEN // 4], False),
            (p + "se_fc2_weight", [HIDDEN, HIDDEN // 4], True),
            (p + "se_fc2_bias", [HIDDEN], False),
        ]
    out += [
        ("encoder.adapter_0_weight", [WIDE, 2, HIDDEN], True),
        ("encoder.adapter_0_bias", [WIDE], False),
        ("encoder.spatial_head_lambda_proj_weight", [1, WIDE], True),
        ("encoder.spatial_head_lambda_proj_bias", [1], False),
        ("encoder.spatial_head_coeff_proj_weight", [COEFFICIENTS, WIDE], True),
        ("encoder.spatial_head_coeff_proj_bias", [COEFFICIENTS], False),
    ]
    return out


class Flatbuffer:
    """Just enough of flatbuffers to read the XNNPACK graph's constant table."""

    def __init__(self, buffer):
        self.b = buffer

    def u32(self, at):
        return struct.unpack_from("<I", self.b, at)[0]

    def field(self, table, slot):
        vtable = table - struct.unpack_from("<i", self.b, table)[0]
        offset = 4 + 2 * slot
        if offset >= struct.unpack_from("<H", self.b, vtable)[0]:
            return None
        relative = struct.unpack_from("<H", self.b, vtable + offset)[0]
        return table + relative if relative else None

    def vector(self, table, slot):
        at = self.field(table, slot)
        if at is None:
            return []
        start = at + self.u32(at)
        return [start + 4 + 4 * i for i in range(self.u32(start))]

    def table_at(self, at):
        return at + self.u32(at)

    def string(self, table, slot):
        at = self.field(table, slot)
        start = at + self.u32(at)
        return self.b[start + 4 : start + 4 + self.u32(start)].decode()

    def scalars(self, table, slot, fmt):
        at = self.field(table, slot)
        if at is None:
            return []
        start = at + self.u32(at)
        size = struct.calcsize(fmt)
        return [struct.unpack_from(fmt, self.b, start + 4 + size * i)[0] for i in range(self.u32(start))]

    def number(self, table, slot, fmt):
        at = self.field(table, slot)
        return 0 if at is None else struct.unpack_from(fmt, self.b, at)[0]


def delegate_constants(blob):
    assert blob[4:8] == b"XH00"
    offset, size = struct.unpack_from("<II", blob, 10)
    fb = Flatbuffer(blob[offset : offset + size])
    root = fb.u32(0)
    names = [fb.string(fb.table_at(at), 2) if fb.field(fb.table_at(at), 2) else "" for at in fb.vector(root, 8)]
    found = {}
    for value in fb.vector(root, 2):
        value = fb.table_at(value)
        union_table = fb.field(value, 1)
        if union_table is None:
            continue
        tensor = fb.table_at(union_table)
        index = fb.number(tensor, 3, "<I")
        if index:
            found[names[index]] = fb.scalars(tensor, 2, "<I")
    return found


def encoder_tensors(raw):
    from executorch.exir._serialize._program import deserialize_pte_binary
    from executorch.exir.schema import DelegateCall

    pte = deserialize_pte_binary(raw)
    plan = pte.program.execution_plan[0]
    store = pte.named_data
    named = {}
    for delegate in plan.delegates:
        for key, dims in delegate_constants(pte.program.backend_delegate_data[delegate.processed.index].data).items():
            if key in store.pte_data:
                data = store.buffers[store.pte_data[key].buffer_index]
                named[re.sub(r"_[0-9a-f]{64}$", "", key)] = np.frombuffer(data, np.float32).reshape(dims)
    out = {}
    for key, value in named.items():
        if value.ndim == 4:
            value = value.reshape(value.shape[0], value.shape[1], value.shape[3])
        out["encoder." + key.removeprefix("p_encoder_")] = value
    # GRN gamma/beta are passed to delegates as program constants of shape (1, 256, 1), in call order.
    pairs = []
    for instruction in plan.chains[0].instructions:
        call = instruction.instr_args
        if not isinstance(call, DelegateCall):
            continue
        for i in call.args:
            value = plan.values[i].val
            if type(value).__name__ == "Tensor" and value.data_buffer_idx and value.scalar_type.name == "FLOAT":
                shape = list(value.sizes)
                if shape == [1, WIDE, 1]:
                    storage = pte.program.constant_buffer[value.data_buffer_idx].storage
                    pairs.append(np.frombuffer(storage, np.float32, WIDE).copy())
    assert len(pairs) == 2 * BLOCKS, len(pairs)
    for b in range(BLOCKS):
        out[f"encoder.backbone_blocks_{b}_grn_gamma"] = pairs[2 * b]
        out[f"encoder.backbone_blocks_{b}_grn_beta"] = pairs[2 * b + 1]
    return out


def padded(n):
    return (n + 7) // 8 * 8


def pack(tensors):
    body = []
    for name, shape, matrix in entries():
        values = np.asarray(tensors[name], np.float32).reshape(-1)
        assert values.size == int(np.prod(shape)), (name, values.shape, shape)
        if matrix:
            outputs = shape[0]
            inputs = values.size // outputs
            block = np.zeros((inputs, padded(outputs)), np.float32)
            block[:, :outputs] = values.reshape(outputs, inputs).T
            body.append(block.reshape(-1))
        else:
            vector = np.zeros(padded(values.size), np.float32)
            vector[: values.size] = values
            body.append(vector)
    floats = np.concatenate(body).astype("<f4")
    return b"TSE1" + struct.pack("<I", floats.size) + bytes(8) + floats.tobytes()


def main():
    source, target = sys.argv[1:3]
    raw = open(source, "rb").read()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != ENCODER_SHA256:
        sys.exit(f"unexpected encoder sha256 {digest}")
    out = pack(encoder_tensors(raw))
    open(target, "wb").write(out)
    print(f"{len(out)} bytes, sha256 {hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
