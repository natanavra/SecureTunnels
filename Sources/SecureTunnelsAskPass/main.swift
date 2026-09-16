import Foundation
import SecureTunnelsCore

// ssh runs this helper with the prompt as its only argument and reads the answer from stdout.
// The secrets arrive on stdin (inherited from the ssh process) as an AskPassPayload JSON document.
let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONDecoder().decode(AskPassPayload.self, from: input)) ?? AskPassPayload()

if let answer = AskPassResponder.answer(prompt: prompt, payload: payload) {
  print(answer)
  exit(0)
}

FileHandle.standardError.write(Data("SecureTunnelsAskPass: no stored secret for prompt: \(prompt)\n".utf8))
exit(1)
