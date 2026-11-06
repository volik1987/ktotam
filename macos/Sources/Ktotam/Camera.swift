import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Источник кадров: камера ноутбука (или папка с фото для теста — `--fake-camera <папка>`).
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "ktotam.camera", qos: .userInitiated)
    /// Вызывается на очереди камеры; пока обработчик работает, новые кадры отбрасываются.
    var onFrame: ((CIImage) -> Void)?
    private var fakeTimer: DispatchSourceTimer?

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    /// Запуск с выбранной камерой (nil — встроенная). Возвращает текст ошибки или nil.
    func start(deviceId: String?) -> String? {
        stop()
        let all = Camera.devices()
        guard let dev = all.first(where: { $0.uniqueID == deviceId })
                ?? all.first(where: { $0.deviceType == .builtInWideAngleCamera })
                ?? all.first else { return "Камера не найдена" }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else { session.commitConfiguration(); return "Камера занята" }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            return "Камера: \(error.localizedDescription)"
        }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
        return nil
    }

    /// Вместо камеры — по кругу фото из папки (для автотестов без камеры).
    /// Пустая строка в списке (файл "_empty") — кадр без людей.
    func startFake(folder: URL, fps: Double = 5) {
        stop()
        let exts = ["jpg", "jpeg", "png", "heic"]
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) || $0.lastPathComponent.contains("_empty") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var i = 0
        let blank = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 1 / fps)
        t.setEventHandler { [weak self] in
            guard let self, !files.isEmpty else { return }
            let f = files[i % files.count]
            i += 1
            let img = f.lastPathComponent.contains("_empty") ? blank : (CIImage(contentsOf: f) ?? blank)
            self.onFrame?(img)
        }
        t.resume()
        fakeTimer = t
    }

    func stop() {
        fakeTimer?.cancel(); fakeTimer = nil
        if session.isRunning { queue.async { self.session.stopRunning() } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        onFrame?(CIImage(cvPixelBuffer: pb))
    }
}
