import 'dart:io';
import 'dart:isolate';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_classification_mobilenet/image_utils.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// Result from a single inference — classification scores + CAM feature map.
class InferenceResult {
  final Map<String, double> classification;
  /// Flattened feature map from last conv layer: length = 7×7×1280 = 63,616.
  /// Layout: [y][x][channel] → index = y*7*1280 + x*1280 + channel.
  final List<double> featureMap;
  /// Predicted class index (argmax of softmax scores).
  final int predClass;

  const InferenceResult({
    required this.classification,
    required this.featureMap,
    required this.predClass,
  });
}

class IsolateInference {
  static const String _debugName = 'TFLITE_INFERENCE';
  final ReceivePort _receivePort = ReceivePort();
  late Isolate _isolate;
  late SendPort _sendPort;

  SendPort get sendPort => _sendPort;

  Future<void> start() async {
    _isolate = await Isolate.spawn<SendPort>(
        entryPoint, _receivePort.sendPort,
        debugName: _debugName);
    _sendPort = await _receivePort.first;
  }

  Future<void> close() async {
    _isolate.kill();
    _receivePort.close();
  }

  static void entryPoint(SendPort sendPort) async {
    final port = ReceivePort();
    sendPort.send(port.sendPort);

    await for (final InferenceModel model in port) {
      // ── Pre-process image ───────────────────────────────────────────────
      image_lib.Image? img;
      if (model.isCameraFrame()) {
        img = ImageUtils.convertCameraImage(model.cameraImage!);
      } else {
        img = model.image;
      }

      image_lib.Image input = image_lib.copyResize(
        img!,
        width:  model.inputShape[1],
        height: model.inputShape[2],
      );

      if (Platform.isAndroid && model.isCameraFrame()) {
        input = image_lib.copyRotate(input, angle: 90);
      }

      final imageMatrix = List.generate(
        input.height, (y) => List.generate(input.width, (x) {
          final px = input.getPixel(x, y);
          return [px.r / 255.0, px.g / 255.0, px.b / 255.0];
        }),
      );

      // ── Run dual-output inference ────────────────────────────────────────
      // Output 0: feature map  [1, 7, 7, 1280]
      // Output 1: class scores [1, 7]
      final featOutput = List.generate(1, (_) =>
          List.generate(7, (_) =>
              List.generate(7, (_) =>
                  List<double>.filled(1280, 0.0))));
      final scoreOutput = [List<double>.filled(model.outputShape[1], 0.0)];

      final interpreter = Interpreter.fromAddress(model.interpreterAddress);
      interpreter.runForMultipleInputs(
        [[imageMatrix]],
        {0: featOutput, 1: scoreOutput},
      );

      final rawScores = scoreOutput.first;

      // ── Softmax ──────────────────────────────────────────────────────────
      final maxLogit = rawScores.reduce((a, b) => a > b ? a : b);
      final exps     = rawScores.map((v) => _exp(v - maxLogit)).toList();
      final sumExp   = exps.reduce((a, b) => a + b);
      final probs    = exps.map((v) => v / sumExp).toList();

      // ── Classification map ───────────────────────────────────────────────
      final classification = <String, double>{};
      int predClass = 0;
      double bestProb = 0;
      for (int i = 0; i < probs.length; i++) {
        classification[model.labels[i]] = probs[i];
        if (probs[i] > bestProb) { bestProb = probs[i]; predClass = i; }
      }

      // ── Flatten feature map [7,7,1280] → List<double> ───────────────────
      final flatFeatures = <double>[];
      for (int y = 0; y < 7; y++) {
        for (int x = 0; x < 7; x++) {
          for (int k = 0; k < 1280; k++) {
            flatFeatures.add(featOutput[0][y][x][k]);
          }
        }
      }

      model.responsePort.send(InferenceResult(
        classification: classification,
        featureMap:     flatFeatures,
        predClass:      predClass,
      ));
    }
  }
}

double _exp(double x) =>
    x > 88.0 ? 6.565e38 : x < -88.0 ? 0.0 : _mathExp(x);

double _mathExp(double x) {
  if (x == 0) return 1.0;
  if (x > 0) {
    double result = 1.0, term = 1.0;
    for (int i = 1; i <= 20; i++) { term *= x / i; result += term; }
    return result;
  }
  return 1.0 / _mathExp(-x);
}

class InferenceModel {
  CameraImage? cameraImage;
  image_lib.Image? image;
  int interpreterAddress;
  List<String> labels;
  List<int> inputShape;
  List<int> outputShape;
  late SendPort responsePort;

  InferenceModel(this.cameraImage, this.image, this.interpreterAddress,
      this.labels, this.inputShape, this.outputShape);

  bool isCameraFrame() => cameraImage != null;
}