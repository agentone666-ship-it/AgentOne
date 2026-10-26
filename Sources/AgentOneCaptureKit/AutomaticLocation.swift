@preconcurrency import CoreLocation
import Foundation

public struct LocationObservation: Codable, Sendable, Equatable {
    public let latitude:Double
    public let longitude:Double
    public let horizontalAccuracy:Double
    public let observedAt:Date
    public var label:String?
    public init?(latitude:Double,longitude:Double,horizontalAccuracy:Double,observedAt:Date,label:String? = nil) {
        guard latitude.isFinite,longitude.isFinite,horizontalAccuracy.isFinite,(-90...90).contains(latitude),(-180...180).contains(longitude),horizontalAccuracy>0,horizontalAccuracy<=5000 else {return nil}
        self.latitude=latitude;self.longitude=longitude;self.horizontalAccuracy=horizontalAccuracy;self.observedAt=observedAt;self.label=label
    }
    public func isFresh(at now:Date=Date()) -> Bool {let age=now.timeIntervalSince(observedAt);return age>=(-10) && age<=600}
    public var displayName:String {label.flatMap {$0.isEmpty ? nil:$0} ?? String(format:"%.4f, %.4f",latitude,longitude)}
    public var json:[String:Any] {
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        return ["provider":"core_location","latitude":latitude,"longitude":longitude,"horizontal_accuracy_m":horizontalAccuracy,"observed_at":formatter.string(from:observedAt),"label":label ?? NSNull()]}
}

/// System authorization and periodic one-shot fixes; no IP lookup or inferred workplace name.
@MainActor public final class AutomaticLocationService:NSObject,CLLocationManagerDelegate {
    private let manager=CLLocationManager()
    private let geocoder=CLGeocoder()
    private var timer:Task<Void,Never>?
    private var timeout:Task<Void,Never>?
    private var lastGeocoded:CLLocation?
    private var lastAddress:String?
    private var requestStarted=false
    public private(set) var enabled=false
    public private(set) var status="自动定位尚未启动"
    private var latest:LocationObservation?
    public var observation:LocationObservation? {guard enabled,let latest,latest.isFresh() else {return nil};return latest}
    public var onChange:(@MainActor @Sendable ()->Void)?
    public override init() {super.init();manager.delegate=self;manager.desiredAccuracy=kCLLocationAccuracyHundredMeters}
    public func start(requestPermission:Bool) {
        enabled=true
        switch manager.authorizationStatus {
        case .notDetermined:
            status="等待允许定位";if requestPermission {manager.requestWhenInUseAuthorization()}
        case .authorizedAlways,.authorizedWhenInUse:
            requestFix();beginTimer()
        case .denied,.restricted:
            latest=nil
            status=CLLocationManager.locationServicesEnabled() ? "定位未获允许，地点未知":"系统定位服务已关闭，请在定位设置中开启"
        @unknown default:latest=nil;status="定位状态未知"
        }
        onChange?()
    }
    public func stop(status:String="自动定位已关闭") {enabled=false;timer?.cancel();timer=nil;timeout?.cancel();timeout=nil;requestStarted=false;manager.stopUpdatingLocation();geocoder.cancelGeocode();latest=nil;self.status=status;onChange?()}
    public func refresh() {guard enabled else {return};start(requestPermission:false)}
    private func beginTimer() {
        guard timer==nil else {return}
        timer=Task { [weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(180))} catch {return}
                self?.requestFix()
            }
        }
    }
    private func requestFix() {
        guard enabled,!requestStarted else {return}
        requestStarted=true;status="正在自动定位…";manager.requestLocation()
        timeout?.cancel();timeout=Task { [weak self] in
            do {try await Task.sleep(for:.seconds(25))} catch {return}
            guard let self else {return}
            self.requestStarted=false;self.manager.stopUpdatingLocation();self.status=self.observation==nil ? "暂时无法定位，地点未知":"暂时无法更新，使用最近有效位置";self.onChange?()
        }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        Task { @MainActor [weak self] in guard let self,self.enabled else {return};self.start(requestPermission:false) }
    }
    nonisolated public func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        let fix=locations.last.flatMap {LocationObservation(latitude:$0.coordinate.latitude,longitude:$0.coordinate.longitude,horizontalAccuracy:$0.horizontalAccuracy,observedAt:$0.timestamp)}
        Task { @MainActor [weak self] in self?.accept(fix) }
    }
    nonisolated public func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {
        Task { @MainActor [weak self] in
            guard let self,self.enabled else {return};self.timeout?.cancel();self.timeout=nil;self.requestStarted=false
            self.status="暂时无法定位，稍后自动重试";self.onChange?()
        }
    }
    private func accept(_ fix:LocationObservation?) {
        guard enabled else {return}
        timeout?.cancel();timeout=nil;requestStarted=false
        guard var fix,fix.isFresh() else {status="位置结果过旧或精度不足，地点未知";onChange?();return}
        let native=CLLocation(latitude:fix.latitude,longitude:fix.longitude)
        if let lastGeocoded,native.distance(from:lastGeocoded)<150 {fix.label=lastAddress}
        latest=fix;status="系统定位 · 约 ±\(Int(fix.horizontalAccuracy.rounded())) 米";onChange?()
        guard fix.label==nil else {return}
        geocoder.cancelGeocode()
        let sampledAt=fix.observedAt
        geocoder.reverseGeocodeLocation(native,preferredLocale:Locale(identifier:"zh_CN")) { [weak self] places,_ in
            let parts=places?.first.map {[$0.locality,fix.horizontalAccuracy<=1000 ? $0.subLocality:nil,fix.horizontalAccuracy<=250 ? $0.thoroughfare:nil].compactMap {$0}.filter {!$0.isEmpty}} ?? []
            let label=parts.reduce(into:[String]()) {if !$0.contains($1) {$0.append($1)}}.joined(separator:" · ")
            Task { @MainActor in
                guard let self,self.enabled,self.latest?.observedAt==sampledAt,!label.isEmpty else {return}
                self.latest?.label=label;self.lastAddress=label;self.lastGeocoded=CLLocation(latitude:fix.latitude,longitude:fix.longitude);self.onChange?()
            }
        }
    }
}
