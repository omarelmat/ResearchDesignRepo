import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'isolate_inference.dart';
import 'cam_helper.dart';

class ImageClassificationHelper {
  static const modelPath  = 'assets/models/limestone_defect_model_cam.tflite';
  static const labelsPath = 'assets/models/limestone_labels.txt';

  late final Interpreter interpreter;
  late final List<String> labels;
  late final IsolateInference isolateInference;
  late Tensor inputTensor;
  late Tensor outputTensor;

  /// Public CAM helper — loaded once, reused everywhere.
  final camHelper = CamHelper();

  Future<void> _loadModel() async {
    final options = InterpreterOptions();
    if (Platform.isAndroid) options.addDelegate(XNNPackDelegate());
    if (Platform.isIOS)     options.addDelegate(GpuDelegate());

    interpreter = await Interpreter.fromAsset(modelPath, options: options);
    inputTensor  = interpreter.getInputTensors().first;
    // outputTensor refers to the SCORES output (index 1, shape [1,7])
    outputTensor = interpreter.getOutputTensors()[1];
    log('CAM model loaded');
  }

  Future<void> _loadLabels() async {
    final txt = await rootBundle.loadString(labelsPath);
    labels = txt.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  Future<void> initHelper() async {
    await Future.wait([
      _loadLabels(),
      _loadModel(),
      camHelper.loadWeights(),
    ]);
    isolateInference = IsolateInference();
    await isolateInference.start();
  }

  Future<InferenceResult> _inference(InferenceModel model) async {
    final responsePort = ReceivePort();
    isolateInference.sendPort.send(model..responsePort = responsePort.sendPort);
    return await responsePort.first as InferenceResult;
  }

  Future<InferenceResult> inferenceCameraFrame(CameraImage cameraImage) async {
    return _inference(InferenceModel(
      cameraImage, null, interpreter.address,
      labels, inputTensor.shape, outputTensor.shape,
    ));
  }

  Future<InferenceResult> inferenceImage(Image image) async {
    return _inference(InferenceModel(
      null, image, interpreter.address,
      labels, inputTensor.shape, outputTensor.shape,
    ));
  }

  Future<void> close() async => isolateInference.close();
}