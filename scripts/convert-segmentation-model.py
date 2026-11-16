# /// script
# requires-python = "==3.12.*"
# dependencies = [
#     "coremltools==9.0",
#     "numpy",
#     "onnx",
#     "onnxruntime",
#     "torch==2.7.0",
# ]
# ///
"""Makes Models/SpeakerSegmentation.mlpackage, the model transcribe --identify-speakers finds who talks when with:
pyannote's segmentation-3.0 (https://huggingface.co/pyannote/segmentation-3.0, MIT), from its ONNX export
(https://huggingface.co/onnx-community/pyannote-segmentation-3.0), converted to Core ML and checked against the original.
It hears 10 s of 16 kHz audio and says, for each of 589 frames, which of up to 3 speakers talk: one of 7 classes,
nobody, each alone, or each pair. The export's graph branches on the number of channels, which no converter takes, so
the network is built again here, as pyannote's PyanNet, with the export's weights. Run it only to change the model,
with uv:
uv run scripts/convert-segmentation-model.py [<output.mlpackage>]
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
import onnxruntime
import torch
from onnx import numpy_helper
from torch import nn

URL = (
    "https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/"
    "733a93b6473d019a773298e08cefa686894b1854/onnx/model.onnx"
)
SHA256 = "057ee564753071c0b09b5b611648b50ac188d50846bff5f01e9f7bbf1591ea25"
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Models" / "SpeakerSegmentation.mlpackage"
SAMPLES = 160_000
# The export's names for its LSTMs' weights, layer by layer: input, recurrent, bias.
LSTM_WEIGHTS = [(784, 785, 783), (827, 828, 826), (870, 871, 869), (913, 914, 912)]


class PyanNet(nn.Module):
    """SincNet's learned band-pass filters and pooling, 4 bidirectional LSTMs, 2 linear layers and the classifier."""

    def __init__(self, weights):
        super().__init__()

        def parameter(name):
            return nn.Parameter(torch.from_numpy(weights[name].copy()), requires_grad=False)

        def norm(name, channels):
            layer = nn.InstanceNorm1d(channels, affine=True, eps=1e-5)
            layer.weight, layer.bias = parameter(f"{name}.weight"), parameter(f"{name}.bias")
            return layer

        def conv(name, inputs):
            layer = nn.Conv1d(inputs, 60, 5)
            layer.weight, layer.bias = parameter(f"{name}.weight"), parameter(f"{name}.bias")
            return layer

        self.wav_norm = norm("sincnet.wav_norm1d", 1)
        self.filters = parameter("/sincnet/conv1d.0/Concat_2_output_0")
        self.norms = nn.ModuleList([norm(f"sincnet.norm1d.{i}", n) for i, n in enumerate((80, 60, 60))])
        self.convs = nn.ModuleList([conv("sincnet.conv1d.1", 80), conv("sincnet.conv1d.2", 60)])
        self.lstm = nn.LSTM(60, 128, num_layers=4, bidirectional=True, batch_first=True)
        # ONNX orders an LSTM's gates input, output, forget, cell; PyTorch input, forget, cell, output.
        order = np.concatenate([np.arange(g * 128, (g + 1) * 128) for g in (0, 2, 3, 1)])
        for layer, (w, r, b) in enumerate(LSTM_WEIGHTS):
            for direction, suffix in enumerate(("", "_reverse")):
                bias = weights[f"onnx::LSTM_{b}"][direction]
                values = {
                    "weight_ih": weights[f"onnx::LSTM_{w}"][direction][order],
                    "weight_hh": weights[f"onnx::LSTM_{r}"][direction][order],
                    "bias_ih": bias[:512][order],
                    "bias_hh": bias[512:][order],
                }
                for name, value in values.items():
                    getattr(self.lstm, f"{name}_l{layer}{suffix}").data = torch.from_numpy(value.copy())
        self.linears = nn.ModuleList()
        for name, matrix in (("linear.0", 915), ("linear.1", 916), ("classifier", 917)):
            weight = weights[f"onnx::MatMul_{matrix}"]
            layer = nn.Linear(*weight.shape)
            layer.weight = nn.Parameter(torch.from_numpy(weight.T.copy()), requires_grad=False)
            layer.bias = parameter(f"{name}.bias")
            self.linears.append(layer)

    def forward(self, audio):
        x = nn.functional.conv1d(self.wav_norm(audio), self.filters, stride=10).abs()
        x = nn.functional.leaky_relu(self.norms[0](nn.functional.max_pool1d(x, 3)), 0.01)
        for conv, norm in zip(self.convs, self.norms[1:]):
            x = nn.functional.leaky_relu(norm(nn.functional.max_pool1d(conv(x), 3)), 0.01)
        x, _ = self.lstm(x.transpose(1, 2))
        for linear in self.linears[:2]:
            x = nn.functional.leaky_relu(linear(x), 0.01)
        return nn.functional.log_softmax(self.linears[2](x), dim=-1)


def main():
    output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else OUTPUT
    with tempfile.TemporaryDirectory() as directory:
        onnx_path = pathlib.Path(directory) / "model.onnx"
        urllib.request.urlretrieve(URL, onnx_path)
        if hashlib.sha256(onnx_path.read_bytes()).hexdigest() != SHA256:
            raise SystemExit(f"{URL} is not the model this script was written for")

        weights = {i.name: numpy_helper.to_array(i) for i in onnx.load(onnx_path).graph.initializer}
        traced = torch.jit.trace(PyanNet(weights).eval(), torch.randn(1, 1, SAMPLES) * 0.1)
        model = ct.convert(
            traced,
            inputs=[ct.TensorType(name="audio", shape=(1, 1, SAMPLES), dtype=np.float32)],
            outputs=[ct.TensorType(name="classes", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS15,
            # In 16 bits, up to 4% of a window's frames come out a different class, and it runs no faster.
            compute_precision=ct.precision.FLOAT32,
        )
        model.short_description = (
            "pyannote segmentation-3.0, MIT. Input: 10 s of 16 kHz mono audio. Output: for each of 589 frames, the log "
            "probability of each of 7 classes: nobody, speaker 1, 2 or 3 alone, 1 and 2, 1 and 3, 2 and 3."
        )

        # The same class, frame by frame, as the original, on speech-like noise and on silence.
        session = onnxruntime.InferenceSession(str(onnx_path))
        random = np.random.default_rng(0)
        for name, audio in (
            ("noise", (random.standard_normal((1, 1, SAMPLES)) * 0.05).astype(np.float32)),
            ("silence", np.zeros((1, 1, SAMPLES), dtype=np.float32)),
        ):
            want = session.run(None, {"input_values": audio})[0][0]
            got = model.predict({"audio": audio})["classes"].reshape(want.shape)
            agreement = float((want.argmax(1) == got.argmax(1)).mean())
            print(f"{name}: same class in {agreement:.2%} of frames, largest difference {np.abs(want - got).max():.4f}")
            if agreement < 0.99:
                raise SystemExit("the converted model does not match the original")

        shutil.rmtree(output, ignore_errors=True)
        model.save(str(output))
        print(f"wrote {output}")


if __name__ == "__main__":
    main()
