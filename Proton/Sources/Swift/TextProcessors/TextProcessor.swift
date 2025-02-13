//
//  TextProcessor.swift
//  Proton
//
//  Created by Rajdeep Kwatra on 9/1/20.
//  Copyright © 2020 Rajdeep Kwatra. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import UIKit

class TextProcessor: NSObject, NSTextStorageDelegate {
    private(set) var activeProcessors = [TextProcessing]() {
        didSet {
            sortedProcessors = activeProcessors.sorted { $0.priority > $1.priority }
        }
    }
    private var sortedProcessors = [TextProcessing]()

    weak var editor: EditorView?

    init(editor: EditorView) {
        self.editor = editor
    }

    func register(_ processor: TextProcessing) {
        register([processor])
    }

    func unregister(_ processor: TextProcessing) {
        unregister([processor])
    }

    func register(_ processors: [TextProcessing]) {
        activeProcessors.append(contentsOf: processors)
    }

    func unregister(_ processors: [TextProcessing]) {
        activeProcessors.removeAll { p in
            processors.contains { $0.name == p.name }
        }
    }

    func filteringExecutableOn(editor: EditorView) -> [TextProcessing] {
        guard editor.isSettingAttributedText else { return sortedProcessors }
        return sortedProcessors.filter { $0.isRunOnSettingText }
    }

    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard let editor = editor else { return }
        var executedProcessors = [TextProcessing]()
        var processed = false
        let changedText = textStorage.substring(from: editedRange)

        let executableProcessors = filteringExecutableOn(editor: editor)

        executableProcessors.forEach {
            $0.willProcessEditing(editor: editor, editedMask: editedMask, range: editedRange, changeInLength: delta)
        }

        // This func is invoked even when selected range changes without change in text. Guard the code so that delegate call backs are
        // fired only when there is actual change in content
        guard delta != 0 else { return }

        for processor in executableProcessors {
            if changedText == "\n" {
                processor.handleKeyWithModifiers(editor: editor, key: .enter, modifierFlags: [], range: editedRange)
            } else if changedText == "\t" {
                processor.handleKeyWithModifiers(editor: editor, key: .tab, modifierFlags: [], range: editedRange)
            }

            processed = processor.process(editor: editor, range: editedRange, changeInLength: delta)

            if processed { executedProcessors.append(processor) }
            if processor.priority == .exclusive, processed == true {
                notifyInterruption(by: processor, editor: editor, at: editedRange)
                break
            }
        }
        editor.delegate?.editor(editor, didExecuteProcessors: executedProcessors, at: editedRange)
        editor.editorContextDelegate?.editor(editor, didExecuteProcessors: executedProcessors, at: editedRange)
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard let editor = editor else { return }
        let executableProcessors = filteringExecutableOn(editor: editor)

        executableProcessors.forEach {
            $0.didProcessEditing(editor: editor, editedMask: editedMask, range: editedRange, changeInLength: delta)
        }
    }

    func textStorage(_ textStorage: NSTextStorage, willProcessDeletedText deletedText: NSAttributedString, insertedText: NSAttributedString, range: NSRange) {
        guard let editor else { return }
        let executableProcessors = filteringExecutableOn(editor: editor)
        for processor in executableProcessors {
            processor.willProcess(editor: editor, deletedText: deletedText, insertedText: insertedText, range: range)
        }
    }

    private func notifyInterruption(by processor: TextProcessing, editor: EditorView, at range: NSRange) {
        let processors = activeProcessors.filter { $0.name != processor.name }
        processors.forEach { $0.processInterrupted(editor: editor, at: range) }
    }
}
