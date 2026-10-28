import Foundation
@main struct VocalPresenceMixMatchCheck {
 static func main() throws {
  let root = URL(fileURLWithPath: CommandLine.arguments[1])
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String:Any]
  let rows = object["rows"] as! [[String:Any]]; var checked = 0; var maxDelta = 0.0
  for row in rows where row["method"] as! String == "BS.1770 integrated" {
   let modes = (row["pair"] as! String).components(separatedBy: " / ")
   let gains = row["gainDB"] as! [Double]; var measured = [Double]()
   for i in 0..<2 {
    let name = modes[i] + "--" + (row["fixture"] as! String)
    let rate = Double(name.dropLast(4).split(separator:"-").last!)!
    let data = try Data(contentsOf: root.appendingPathComponent(name)); let pcm = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let gain = Float(pow(10, gains[i]/20)); var meter = IntegratedLoudnessMeter(sampleRate:rate,channelCount:2)!
    meter.process(frameCount:pcm.count/2) { c,f in pcm[f*2+c]*gain }
    guard let level = meter.integratedLUFS else { throw NSError(domain:"matched signal gated",code:1) }; measured.append(level)
   }
   let difference = abs(measured[0]-measured[1]); maxDelta = max(maxDelta,difference); checked += 1
   if difference > 0.01 { throw NSError(domain:"mismatched loudness \(row["fixture"]!) \(row["pair"]!) \(difference)",code:1) }
  }
  print("PASS \(checked) integrated loudness pairs, maximum difference \(maxDelta) LU")
 }
}
