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
    @IBOutlet weak var switchCameraButton: UIButton!
    @IBOutlet weak var playButton: UIButton!
    
    // MARK: - Properties
    var captureSession = AVCaptureSession()
    var previewLayer: AVCaptureVideoPreviewLayer!
    var overlayLayer = CAShapeLayer()
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
    
    var isGameActive = false
    var cpuChoice: String?
    var lastDetectedGesture: String? // Store the last valid gesture

    // Frame Throttling
    var frameCounter = 0
    let frameProcessingInterval = 5

    // Camera Position
    var currentCameraPosition: AVCaptureDevice.Position = .front

    // Serial Queue for Capture Session Configuration
    let sessionQueue = DispatchQueue(label: "session queue")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupOverlay()
        setupKeyPointsOverlay()
        updateStreakLabels()
        
        sessionQueue.async {
            self.setupCamera()
            // Start the capture session
            self.captureSession.startRunning()
        }
        
        switchCameraButton.layer.zPosition = 1
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
        if !isGameActive {
            startGame()
        }
    }
    
    @IBAction func switchCameraTapped(_ sender: UIButton) {
        switchCamera()
    }
    
    // MARK: - Game Control Methods
    func startGame() {
        isGameActive = true
        gestureLabel.text = "Get Ready..."
        gestureLabel.textColor = .label
        cpuGestureLabel.text = "CPU Gesture: Hidden"
        cpuGestureLabel.textColor = .label
        cpuChoiceImageView.image = UIImage(named: "question_mark") // Placeholder image
        userChoiceImageView.image = nil

        cpuChoice = randomCPUGesture()
    }
    
    func endGame() {
        isGameActive = false
        gestureLabel.text = "Gesture: None"
        gestureLabel.textColor = .secondaryLabel
        // Do not reset CPU gesture label and image here
        userChoiceImageView.image = nil
        cpuChoice = nil
        lastDetectedGesture = nil // Reset the last detected gesture
    }
    
    // MARK: - Game Logic
    func handleGameLogic(userGesture: String) {
        guard isGameActive, let cpuGesture = cpuChoice else { return }

        isGameActive = false

        // Update CPU gesture label and image
        cpuGestureLabel.text = "CPU Gesture: \(cpuGesture)"
        cpuGestureLabel.textColor = .label
        setCPUChoiceImage(to: cpuGesture)

        // Update user choice image
        setUserChoiceImage(to: userGesture)

        let result: String

        if userGesture.lowercased() == cpuGesture.lowercased() {
            result = "Draw!"
            // Keep current win streak
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
            self.endGame()
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

        // Begin session configuration
        captureSession.beginConfiguration()

        // Remove existing inputs
        captureSession.inputs.forEach { input in
            captureSession.removeInput(input)
        }

        // Add video input
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCameraPosition),
              let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
              captureSession.canAddInput(videoInput) else {
            DispatchQueue.main.async {
                self.showCameraUnavailableAlert()
            }
            captureSession.commitConfiguration()
            return
        }
        captureSession.addInput(videoInput)

        // Remove existing outputs
        if let videoOutput = captureSession.outputs.first as? AVCaptureVideoDataOutput {
            captureSession.removeOutput(videoOutput)
        }

        // Add video output
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

        // Configure connection
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            connection.automaticallyAdjustsVideoMirroring = false // Add this line
            connection.isVideoMirrored = (currentCameraPosition == .front)
        }

        // Commit configuration
        captureSession.commitConfiguration()

        // Update preview layer on main thread
        DispatchQueue.main.async {
            // If previewLayer doesn't exist, create it
            if self.previewLayer == nil {
                self.previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                self.previewLayer.videoGravity = .resizeAspectFill
                self.previewLayer.frame = self.cameraContainerView.bounds

                // Remove existing previewLayer if any
                self.cameraContainerView.layer.sublayers?.removeAll { $0 is AVCaptureVideoPreviewLayer }

                self.cameraContainerView.layer.insertSublayer(self.previewLayer, at: 0)
            }

            // Update previewLayer connection settings
            if let connection = self.previewLayer.connection {
                connection.videoOrientation = .portrait
                connection.automaticallyAdjustsVideoMirroring = false // Add this line
                connection.isVideoMirrored = (self.currentCameraPosition == .front)
            }

            // Ensure overlay layers have correct frame
            self.overlayLayer.frame = self.cameraContainerView.bounds
            self.keyPointsLayer.frame = self.cameraContainerView.bounds

            // Remove existing overlay layers
            self.overlayLayer.removeFromSuperlayer()
            self.keyPointsLayer.removeFromSuperlayer()

            // Add overlay layers
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
        overlayLayer.strokeColor = UIColor.systemRed.cgColor
        overlayLayer.lineWidth = 2
        overlayLayer.fillColor = UIColor.clear.cgColor
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

            self.drawKeyPointsWithConnections(points)

            if let gesture = self.detectHandGesture(observation) {
                // New valid gesture detected
                if gesture != self.lastDetectedGesture {
                    self.lastDetectedGesture = gesture
                    self.gestureLabel.text = "Gesture: \(gesture)"
                    self.gestureLabel.textColor = .label

                    if self.isGameActive {
                        self.handleGameLogic(userGesture: gesture)
                    }
                }
            } else if let lastGesture = self.lastDetectedGesture {
                // No new gesture detected, continue showing last gesture
                self.gestureLabel.text = "Gesture: \(lastGesture)"
                self.gestureLabel.textColor = .secondaryLabel
            }
            // If there's no last gesture, do not update the label
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

        guard let wrist = wristPoint, wrist.confidence > 0.3,
              let indexTip = indexTipPoint, indexTip.confidence > 0.3,
              let middleTip = middleTipPoint, middleTip.confidence > 0.3,
              let ringTip = ringTipPoint, ringTip.confidence > 0.3,
              let littleTip = littleTipPoint, littleTip.confidence > 0.3,
              let thumbTip = thumbTipPoint, thumbTip.confidence > 0.3 else { return nil }

        let indexDistance = distanceBetween(wrist.location, indexTip.location)
        let middleDistance = distanceBetween(wrist.location, middleTip.location)
        let ringDistance = distanceBetween(wrist.location, ringTip.location)
        let littleDistance = distanceBetween(wrist.location, littleTip.location)
        let thumbDistance = distanceBetween(wrist.location, thumbTip.location)

        let extendedThreshold: CGFloat = 0.2

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
            // Return nil instead of "Uncertain"
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
            lineLayer.strokeColor = UIColor.systemGreen.cgColor
            lineLayer.lineWidth = 2
            keyPointsLayer.addSublayer(lineLayer)
        }
        
        for (_, point) in points where point.confidence > 0.5 {
            let point = convertFromVisionPoint(point.location)
            let circlePath = UIBezierPath(arcCenter: point, radius: 4, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: true)
            let shapeLayer = CAShapeLayer()
            shapeLayer.path = circlePath.cgPath
            shapeLayer.fillColor = UIColor.systemYellow.cgColor
            keyPointsLayer.addSublayer(shapeLayer)
        }
    }
    
    // MARK: - Camera Switching
    func switchCamera() {
        currentCameraPosition = (currentCameraPosition == .front) ? .back : .front
        
        sessionQueue.async {
            // Begin session configuration
            self.captureSession.beginConfiguration()

            // Remove existing inputs
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }

            // Add new input
            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.currentCameraPosition),
                  let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
                  self.captureSession.canAddInput(videoInput) else {
                DispatchQueue.main.async {
                    self.showCameraUnavailableAlert()
                }
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(videoInput)

            // Update video output connection settings
            if let videoOutput = self.captureSession.outputs.first as? AVCaptureVideoDataOutput,
               let connection = videoOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
                connection.automaticallyAdjustsVideoMirroring = false // Add this line
                connection.isVideoMirrored = (self.currentCameraPosition == .front)
            }

            // Commit session configuration
            self.captureSession.commitConfiguration()

            // Update preview layer on main thread
            DispatchQueue.main.async {
                if let connection = self.previewLayer.connection {
                    connection.videoOrientation = .portrait
                    connection.automaticallyAdjustsVideoMirroring = false // Add this line
                    connection.isVideoMirrored = (self.currentCameraPosition == .front)
                }
            }
        }
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
        case .portrait:
            return currentCameraPosition == .front ? .leftMirrored : .right
        case .portraitUpsideDown:
            return currentCameraPosition == .front ? .rightMirrored : .left
        case .landscapeLeft:
            return currentCameraPosition == .front ? .downMirrored : .up
        case .landscapeRight:
            return currentCameraPosition == .front ? .upMirrored : .down
        default:
            // Default to portrait
            return currentCameraPosition == .front ? .leftMirrored : .right
        }
    }
}
