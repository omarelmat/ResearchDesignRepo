/*
 * Copyright 2023 The TensorFlow Authors. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *             http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 
import 'dart:io';
import 'dart:isolate';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as image_lib;
import 'package:image_classification_mobilenet/image_utils.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
 
class IsolateInference {
  static const String _debugName = "TFLITE_INFERENCE";
  final ReceivePort _receivePort = ReceivePort();
  late Isolate _isolate;
  late SendPort _sendPort;
 
  SendPort get sendPort => _sendPort;
 
  Future<void> start() async {
    _isolate = await Isolate.spawn<SendPort>(entryPoint, _receivePort.sendPort,
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
 
    await for (final InferenceModel isolateModel in port) {
      image_lib.Image? img;
      if (isolateModel.isCameraFrame()) {
        img = ImageUtils.convertCameraImage(isolateModel.cameraImage!);
      } else {
        img = isolateModel.image;
      }
 
      // resize original image to match model shape.
      image_lib.Image imageInput = image_lib.copyResize(
        img!,
        width: isolateModel.inputShape[1],
        height: isolateModel.inputShape[2],
      );
 
      if (Platform.isAndroid && isolateModel.isCameraFrame()) {
        imageInput = image_lib.copyRotate(imageInput, angle: 90);
      }
 
      final imageMatrix = List.generate(
        imageInput.height,
        (y) => List.generate(
          imageInput.width,
          (x) {
            final pixel = imageInput.getPixel(x, y);
            // ✅ CHANGED: normalize to [0.0, 1.0] for float32 model
            return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
          },
        ),
      );
 
      // Set tensor input [1, 224, 224, 3]
      final input = [imageMatrix];
      // ✅ CHANGED: double output instead of int — float32 model returns doubles
      final output = [List<double>.filled(isolateModel.outputShape[1], 0.0)];
      // // Run inference
      Interpreter interpreter =
          Interpreter.fromAddress(isolateModel.interpreterAddress);
      interpreter.run(input, output);
      // Get first output tensor
      final result = output.first;
 
      // Apply softmax to convert raw logits → true probabilities (0.0–1.0)
      final maxLogit = result.reduce((a, b) => a > b ? a : b);
      final expValues = result.map((v) => _exp(v - maxLogit)).toList();
      final sumExp = expValues.reduce((a, b) => a + b);
      final probabilities = expValues.map((v) => v / sumExp).toList();
 
      var classification = <String, double>{};
      for (var i = 0; i < probabilities.length; i++) {
        classification[isolateModel.labels[i]] = probabilities[i];
      }
      isolateModel.responsePort.send(classification);
    }
  }
}
 
double _exp(double x) {
  // Clamp to avoid overflow on extreme logits
  return x > 88.0 ? 6.565e38 : x < -88.0 ? 0.0 : _mathExp(x);
}
 
double _mathExp(double x) {
  // Simple iterative approximation safe for isolate
  // Actually just leverage dart:core double operations
  const double e = 2.718281828459045;
  if (x == 0) return 1.0;
  if (x > 0) {
    double result = 1.0;
    double term = 1.0;
    for (int i = 1; i <= 20; i++) {
      term *= x / i;
      result += term;
    }
    return result;
  } else {
    return 1.0 / _mathExp(-x);
  }
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
 
  // check if it is camera frame or still image
  bool isCameraFrame() {
    return cameraImage != null;
  }
}