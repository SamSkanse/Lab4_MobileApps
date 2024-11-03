import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {
    
    // MARK: - IBOutlets
    @IBOutlet weak var gestureLabel: UILabel!
    @IBOutlet weak var streakLabel: UILabel!
    @IBOutlet weak var highScoreLabel: UILabel!
    @IBOutlet weak var cpuGestureLabel: UILabel!
    @IBOutlet weak var cameraContainerView: UIView!
    @IBOutlet weak var cpuChoiceImageView: UIImageView!
    @IBOutlet weak var userChoiceImageView: UIImageView!
    @IBOutlet weak var playButton: UIButton!
    
    // MARK: - Properties
    var captureSession = AVCaptureSession()
    var previewLayer: AVCaptureVideoPreviewLayer!
    var overlayLayer = CALayer()
    var keyPointsLayer = CAShapeLayer()

    var currentWinStreak = 0
    var highScoreWinStreak: Int {
        get {
            UserDefaults.standard.integer(forKey: "highScoreWinStreak")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "highScoreWinStreak")
        }
    }
    
    var cpuChoice: String?
    var lastDetectedGesture: String?

    var frameCounter = 0
    let frameProcessingInterval = 5

    let sessionQueue = DispatchQueue(label: "session queue")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupOverlay()
        setupKeyPointsOverlay()
        updateStreakLabels()
        
        cpuChoiceImageView.image = UIImage(named: "question_mark")
        
        sessionQueue.async {
            self.setupCamera()
            self.captureSession.startRunning()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        previewLayer?.frame = cameraContainerView.bounds
        overlayLayer.frame = cameraContainerView.bounds
        keyPointsLayer.frame = cameraContainerView.bounds
    }
    
    // MARK: - IBActions
    @IBAction func playButtonTapped(_ sender: UIButton) {
        guard let userGesture = self.lastDetectedGesture else {
            let alert = UIAlertController(title: "No Gesture Detected",
                                          message: "Please perform a gesture before pressing Play Game.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            DispatchQueue.main.async {
                self.present(alert, animated: true)
            }
            return
        }
        
        let cpuGesture = randomCPUGesture()
        self.cpuChoice = cpuGesture
        
        setCPUChoiceImage(to: cpuGesture)
        cpuGestureLabel.text = "CPU Gesture: \(cpuGesture)"
        cpuGestureLabel.textColor = .label

        handleGameLogic(userGesture: userGesture)
    }
    
    // MARK: - Game Logic
    func handleGameLogic(userGesture: String) {
        guard let cpuGesture = cpuChoice else { return }
        
        let result: String
        
        if userGesture.lowercased() == cpuGesture.lowercased() {
            result = "Draw!"
        } else if (userGesture.lowercased() == "rock" && cpuGesture.lowercased() == "scissors") ||
                    (userGesture.lowercased() == "paper" && cpuGesture.lowercased() == "rock") ||
                    (userGesture.lowercased() == "scissors" && cpuGesture.lowercased() == "paper") {
            result = "You win!"
            currentWinStreak += 1
            updateHighScore()
        } else {
            result = "You lose!"
            currentWinStreak = 0
        }

        updateStreakLabels()
        showResultAlert(result: result, cpuGesture: cpuGesture) {
            self.cpuChoiceImageView.image = UIImage(named: "question_mark")
            self.cpuGestureLabel.text = "CPU Gesture: Hidden"
            self.cpuChoice = nil
        }
    }
    
    // MARK: - Result Alert
    func showResultAlert(result: String, cpuGesture: String, completion: @escaping () -> Void) {
        let alert = UIAlertController(title: result,
                                      message: "CPU chose \(cpuGesture)",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            completion()
        }))
        DispatchQueue.main.async {
            self.present(alert, animated: true)
        }
    }
    
    // MARK: - Camera Setup
    func setupCamera() {
        captureSession.sessionPreset = .high

        captureSession.beginConfiguration()

        captureSession.inputs.forEach { input in
            captureSession.removeInput(input)
        }

        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            DispatchQueue.main.async {
                self.showCameraUnavailableAlert()
            }
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)

        if let videoOutput = captureSession.outputs.first as? AVCaptureVideoDataOutput {
            captureSession.removeOutput(videoOutput)
        }

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        } else {
            DispatchQueue.main.async {
                self.showCameraUnavailableAlert()
            }
            captureSession.commitConfiguration()
            return
        }

        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        captureSession.commitConfiguration()

        DispatchQueue.main.async {
            if self.previewLayer == nil {
                self.previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                self.previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer.frame = self.cameraContainerView.bounds

                self.cameraContainerView.layer.sublayers?.removeAll { $0 is AVCaptureVideoPreviewLayer }

                self.cameraContainerView.layer.insertSublayer(self.previewLayer, at: 0)
            }

            if let connection = self.previewLayer.connection {
                connection.videoOrientation = .portrait
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }

            self.overlayLayer.frame = self.cameraContainerView.bounds
            self.keyPointsLayer.frame = self.cameraContainerView.bounds

            self.overlayLayer.removeFromSuperlayer()
            self.keyPointsLayer.removeFromSuperlayer()

            self.cameraContainerView.layer.addSublayer(self.overlayLayer)
            self.cameraContainerView.layer.addSublayer(self.keyPointsLayer)
        }
    }
    
    func showCameraUnavailableAlert() {
        let alert = UIAlertController(title: "Camera Unavailable",
                                      message: "Unable to access the camera. Please ensure it is not being used by another application.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DispatchQueue.main.async {
            self.present(alert, animated: true)
        }
    }
    
    // MARK: - Overlay Setup
    func setupOverlay() {
        overlayLayer.frame = cameraContainerView.bounds
        cameraContainerView.layer.addSublayer(overlayLayer)
    }
    
    func setupKeyPointsOverlay() {
        keyPointsLayer.frame = cameraContainerView.bounds
        keyPointsLayer.strokeColor = UIColor.systemGreen.cgColor
        keyPointsLayer.fillColor = UIColor.systemGreen.cgColor
        keyPointsLayer.lineWidth = 2
        keyPointsLayer.lineJoin = .round
        keyPointsLayer.lineCap = .round
    }
    
    // MARK: - UI Updates
    func updateStreakLabels() {
        streakLabel.text = "Current Streak: \(currentWinStreak)"
        highScoreLabel.text = "High Score: \(highScoreWinStreak)"
        streakLabel.textColor = .label
        highScoreLabel.textColor = .label
    }
    
    func updateHighScore() {
        if currentWinStreak > highScoreWinStreak {
            highScoreWinStreak = currentWinStreak
        }
    }
    
    // MARK: - Helper Methods
    func setCPUChoiceImage(to gesture: String) {
        DispatchQueue.main.async {
            UIView.transition(with: self.cpuChoiceImageView,
                              duration: 0.5,
                              options: .transitionCrossDissolve,
                              animations: {
                                  switch gesture.lowercased() {
                                  case "rock":
                                      self.cpuChoiceImageView.image = UIImage(named: "rock")
                                  case "paper":
                                      self.cpuChoiceImageView.image = UIImage(named: "paper")
                                  case "scissors":
                                      self.cpuChoiceImageView.image = UIImage(named: "scissors")
                                  default:
                                      self.cpuChoiceImageView.image = nil
                                  }
                              },
                              completion: nil)
        }
    }
    
    func setUserChoiceImage(to gesture: String) {
        DispatchQueue.main.async {
            UIView.transition(with: self.userChoiceImageView,
                              duration: 0.5,
                              options: .transitionCrossDissolve,
                              animations: {
                                  switch gesture.lowercased() {
                                  case "rock":
                                      self.userChoiceImageView.image = UIImage(named: "rock")
                                  case "paper":
                                      self.userChoiceImageView.image = UIImage(named: "paper")
                                  case "scissors":
                                      self.userChoiceImageView.image = UIImage(named: "scissors")
                                  default:
                                      self.userChoiceImageView.image = nil
                                  }
                              },
                              completion: nil)
        }
    }
    
    func randomCPUGesture() -> String {
        ["Rock", "Paper", "Scissors"].randomElement()!
    }
    
    // MARK: - Gesture Detection
    func processHandPoseObservation(_ observation: VNHumanHandPoseObservation) {
        DispatchQueue.main.async {
            self.overlayLayer.sublayers?.removeAll()
            self.keyPointsLayer.sublayers?.removeAll()

            guard let points = try? observation.recognizedPoints(.all) else { return }

            if let gesture = self.detectHandGesture(observation) {
                self.lastDetectedGesture = gesture
                self.gestureLabel.text = "Gesture: \(gesture)"
                self.gestureLabel.textColor = .label

                self.setUserChoiceImage(to: gesture)
            } else {
                self.gestureLabel.text = "Gesture: None"
                self.gestureLabel.textColor = .secondaryLabel
                self.userChoiceImageView.image = nil
                self.lastDetectedGesture = nil
            }

            // Draw key points and connections
            self.drawKeyPointsWithConnections(points)

            // Draw bounding box around the hand
            self.drawHandBoundingBox(points)
        }
    }
    
    func convertFromVisionPoint(_ point: CGPoint) -> CGPoint {
        let normalizedPoint = CGPoint(x: point.x, y: 1 - point.y)
        let convertedPoint = previewLayer.layerPointConverted(fromCaptureDevicePoint: normalizedPoint)
        return convertedPoint
    }
    
    func detectHandGesture(_ observation: VNHumanHandPoseObservation) -> String? {
        guard let recognizedPoints = try? observation.recognizedPoints(.all) else { return nil }

        let wristPoint = recognizedPoints[.wrist]
        let indexTipPoint = recognizedPoints[.indexTip]
        let middleTipPoint = recognizedPoints[.middleTip]
        let ringTipPoint = recognizedPoints[.ringTip]
        let littleTipPoint = recognizedPoints[.littleTip]
        let thumbTipPoint = recognizedPoints[.thumbTip]

        guard let wrist = wristPoint, wrist.confidence > 0.7,
              let indexTip = indexTipPoint, indexTip.confidence > 0.5,
              let middleTip = middleTipPoint, middleTip.confidence > 0.7,
              let ringTip = ringTipPoint, ringTip.confidence > 0.5,
              let littleTip = littleTipPoint, littleTip.confidence > 0.5,
              let thumbTip = thumbTipPoint, thumbTip.confidence > 0.5 else { return nil }

        let indexDistance = distanceBetween(wrist.location, indexTip.location)
        let middleDistance = distanceBetween(wrist.location, middleTip.location)
        let ringDistance = distanceBetween(wrist.location, ringTip.location)
        let littleDistance = distanceBetween(wrist.location, littleTip.location)
        let thumbDistance = distanceBetween(wrist.location, thumbTip.location)

        let extendedThreshold: CGFloat = 0.18

        let fingersExtended = [
            indexDistance > extendedThreshold,
            middleDistance > extendedThreshold,
            ringDistance > extendedThreshold,
            littleDistance > extendedThreshold,
            thumbDistance > extendedThreshold
        ]

        if fingersExtended.allSatisfy({ !$0 }) {
            return "Rock"
        } else if fingersExtended.allSatisfy({ $0 }) {
            return "Paper"
        } else if fingersExtended[0] && fingersExtended[1] && !fingersExtended[2] && !fingersExtended[3] && !fingersExtended[4] {
            return "Scissors"
        } else {
            return nil
        }
    }
    
    func distanceBetween(_ point1: CGPoint, _ point2: CGPoint) -> CGFloat {
        let deltaX = point1.x - point2.x
        let deltaY = point1.y - point2.y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }
    
    // MARK: - App Lifecycle Handling
    @objc func appDidEnterBackground() {
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
        }
    }

    @objc func appWillEnterForeground() {
        sessionQueue.async {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }
    
    // MARK: - Drawing Key Points and Connections
    func drawKeyPointsWithConnections(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) {
        let connections: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.wrist, .thumbCMC),
            (.thumbCMC, .thumbMP),
            (.thumbMP, .thumbIP),
            (.thumbIP, .thumbTip),
            (.wrist, .indexMCP),
            (.indexMCP, .indexPIP),
            (.indexPIP, .indexDIP),
            (.indexDIP, .indexTip),
            (.wrist, .middleMCP),
            (.middleMCP, .middlePIP),
            (.middlePIP, .middleDIP),
            (.middleDIP, .middleTip),
            (.wrist, .ringMCP),
            (.ringMCP, .ringPIP),
            (.ringPIP, .ringDIP),
            (.ringDIP, .ringTip),
            (.wrist, .littleMCP),
            (.littleMCP, .littlePIP),
            (.littlePIP, .littleDIP),
            (.littleDIP, .littleTip)
        ]
        
        var jointColor: UIColor = .systemGray
        var connectionColor: UIColor = .white
        
        if let gesture = self.lastDetectedGesture {
            switch gesture.lowercased() {
            case "rock":
                jointColor = .systemRed
            case "paper":
                jointColor = .systemGreen
            case "scissors":
                jointColor = .systemBlue
            default:
                break
            }
        }
        
        for (startJoint, endJoint) in connections {
            guard let startPoint = points[startJoint], startPoint.confidence > 0.5,
                  let endPoint = points[endJoint], endPoint.confidence > 0.5 else { continue }
            
            let startCGPoint = convertFromVisionPoint(startPoint.location)
            let endCGPoint = convertFromVisionPoint(endPoint.location)
            
            let path = UIBezierPath()
            path.move(to: startCGPoint)
            path.addLine(to: endCGPoint)
            
            let lineLayer = CAShapeLayer()
            lineLayer.path = path.cgPath
            lineLayer.strokeColor = connectionColor.cgColor
            lineLayer.lineWidth = 2
            keyPointsLayer.addSublayer(lineLayer)
        }
        
        for (_, point) in points where point.confidence > 0.5 {
            let point = convertFromVisionPoint(point.location)
            let circlePath = UIBezierPath(arcCenter: point, radius: 4, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: true)
            let shapeLayer = CAShapeLayer()
            shapeLayer.path = circlePath.cgPath
            shapeLayer.fillColor = jointColor.cgColor
            keyPointsLayer.addSublayer(shapeLayer)
        }
    }

    // MARK: - Drawing Hand Bounding Box
    func drawHandBoundingBox(_ points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]) {
        // Filter out points with low confidence
        let highConfidencePoints = points.values.filter { $0.confidence > 0.5 }
        guard !highConfidencePoints.isEmpty else { return }

        // Convert Vision points to UIView coordinates
        let convertedPoints = highConfidencePoints.map { convertFromVisionPoint($0.location) }

        // Compute the bounding box
        let xValues = convertedPoints.map { $0.x }
        let yValues = convertedPoints.map { $0.y }

        guard let minX = xValues.min(),
              let maxX = xValues.max(),
              let minY = yValues.min(),
              let maxY = yValues.max() else { return }

        let boundingRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Create a CAShapeLayer for the bounding box
        let boundingBoxLayer = CAShapeLayer()
        boundingBoxLayer.frame = self.overlayLayer.bounds
        boundingBoxLayer.strokeColor = UIColor.white.cgColor
        boundingBoxLayer.lineWidth = 2.0
        boundingBoxLayer.fillColor = UIColor.clear.cgColor

        // Create the path
        let path = UIBezierPath(rect: boundingRect)
        boundingBoxLayer.path = path.cgPath

        // Add animation for smooth transitions
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        self.overlayLayer.addSublayer(boundingBoxLayer)
        CATransaction.commit()
    }
}
    
// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        frameCounter += 1
        if frameCounter % frameProcessingInterval != 0 {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let exifOrientation = exifOrientationForCurrentDeviceOrientation()

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: exifOrientation, options: [:])
        let handPoseRequest = VNDetectHumanHandPoseRequest()
        handPoseRequest.maximumHandCount = 1

        do {
            try requestHandler.perform([handPoseRequest])
            if let observation = handPoseRequest.results?.first {
                processHandPoseObservation(observation)
            }
        } catch {
            print("Error performing hand pose request: \(error)")
        }
    }
}

// MARK: - Orientation Helper
extension ViewController {
    func exifOrientationForCurrentDeviceOrientation() -> CGImagePropertyOrientation {
        let deviceOrientation = UIDevice.current.orientation

        switch deviceOrientation {
        case .portrait, .faceUp, .faceDown, .unknown:
            return .leftMirrored // Front camera requires mirrored orientation
        case .portraitUpsideDown:
            return .rightMirrored
        case .landscapeLeft:
            return .downMirrored
        case .landscapeRight:
            return .upMirrored
        @unknown default:
            return .leftMirrored
        }
    }
}
