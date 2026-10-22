# /// script
# requires-python = "==3.12.*"
# dependencies = [
#     "coremltools==9.0",
#     "numpy",
#     "onnx",
#     "onnx2torch",
#     "onnxruntime",
#     "torch==2.7.0",
#     "torchvision==0.22.0",
# ]
# ///
"""Makes Models/SpeakerEmbedding.mlpackage, the speaker model transcribe --identify-speakers tells voices apart with:
WeSpeaker's ResNet34-LM, trained on VoxCeleb (https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM, CC BY
4.0), converted from its ONNX export to Core ML with 16-bit weights, and checked against the original. Run it only to
change the model, with uv: uv run scripts/convert-speaker-model.py [<output.mlpackage>]
"""

import hashlib
import pathlib
import shutil
import sys
import tempfile
import urllib.request

import coremltools as ct
import numpy as np
import onnx
import onnx2torch
import onnxruntime
import torch
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op

URL = (
    "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM/resolve/"
    "f0c48c298fd835726c27956a5d617bad7115627e/voxceleb_resnet34_LM.onnx"
)
SHA256 = "7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068"
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Models" / "SpeakerEmbedding.mlpackage"


@register_torch_op(override=True)
def prod(context, node):
    """The model's statistics pooling takes the product of a shape, which coremltools has no conversion for."""
    inputs = _get_inputs(context, node)
    if len(inputs) > 1 and inputs[1] is not None and inputs[1].val is not None:
        keep = bool(inputs[2].val) if len(inputs) > 2 and inputs[2] is not None else False
        result = mb.reduce_prod(x=inputs[0], axes=[int(inputs[1].val)], keep_dims=keep, name=node.name)
    else:
        result = mb.reduce_prod(x=inputs[0], name=node.name)
    context.add(result)


def main():
    output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    with tempfile.TemporaryDirectory() as directory:
        onnx_path = pathlib.Path(directory) / "model.onnx"
        urllib.request.urlretrieve(URL, onnx_path)
        if hashlib.sha256(onnx_path.read_bytes()).hexdigest() != SHA256:
            raise SystemExit(f"{URL} is not the model this script was written for")

        traced = torch.jit.trace(onnx2torch.convert(onnx.load(onnx_path)).eval(), torch.randn(1, 300, 80))
        model = ct.convert(
            traced,
            inputs=[ct.TensorType(name="features", shape=(1, ct.RangeDim(100, 1000, default=300), 80), dtype=np.float32)],
            outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=ct.precision.FLOAT16,
        )
        model.short_description = (
            "WeSpeaker ResNet34-LM speaker embedding (VoxCeleb), CC BY 4.0. Input: 80-band Kaldi log-mel filterbank "
            "frames of 16 kHz audio, 25 ms every 10 ms, less their mean."
        )

        # Within rounding of the original, for any length the model takes.
        session = onnxruntime.InferenceSession(str(onnx_path))
        random = np.random.default_rng(0)
        for frames in (100, 300, 1000):
            features = random.standard_normal((1, frames, 80)).astype(np.float32) * 3
            want = session.run(None, {"feats": features})[0][0]
            got = model.predict({"features": features})["embedding"].reshape(-1)
            cosine = float(np.dot(want, got) / np.linalg.norm(want) / np.linalg.norm(got))
            print(f"{frames} frames: cosine to the original {cosine:.5f}")
            if cosine < 0.999:
                raise SystemExit("the converted model does not match the original")

        shutil.rmtree(output, ignore_errors=True)
        model.save(str(output))
        print(f"wrote {output}")


if __name__ == "__main__":
    main()
