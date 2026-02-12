// LevenshteinDistanceTests.swift
// SwiftAcervoTests
//
// Tests for the Levenshtein edit distance algorithm.

import Testing
@testable import SwiftAcervo

@Suite("Levenshtein Distance Tests")
struct LevenshteinDistanceTests {

    // MARK: - Identical Strings

    @Test("Identical strings have distance 0")
    func identicalStrings() {
        #expect(levenshteinDistance("hello", "hello") == 0)
    }

    @Test("Identical longer strings have distance 0")
    func identicalLongerStrings() {
        #expect(levenshteinDistance("Qwen2.5-7B-Instruct-4bit", "Qwen2.5-7B-Instruct-4bit") == 0)
    }

    // MARK: - Empty Strings

    @Test("Both empty strings have distance 0")
    func bothEmptyStrings() {
        #expect(levenshteinDistance("", "") == 0)
    }

    @Test("Empty first string returns length of second")
    func emptyFirstString() {
        #expect(levenshteinDistance("", "hello") == 5)
    }

    @Test("Empty second string returns length of first")
    func emptySecondString() {
        #expect(levenshteinDistance("hello", "") == 5)
    }

    // MARK: - Single Character Difference

    @Test("Single character difference gives distance 1")
    func singleCharacterDiff() {
        #expect(levenshteinDistance("cat", "car") == 1)
    }

    // MARK: - Insertion

    @Test("Single insertion gives distance 1")
    func singleInsertion() {
        #expect(levenshteinDistance("cat", "cats") == 1)
    }

    @Test("Insertion at beginning gives distance 1")
    func insertionAtBeginning() {
        #expect(levenshteinDistance("at", "cat") == 1)
    }

    // MARK: - Deletion

    @Test("Single deletion gives distance 1")
    func singleDeletion() {
        #expect(levenshteinDistance("cats", "cat") == 1)
    }

    @Test("Deletion at beginning gives distance 1")
    func deletionAtBeginning() {
        #expect(levenshteinDistance("cat", "at") == 1)
    }

    // MARK: - Substitution

    @Test("Single substitution gives distance 1")
    func singleSubstitution() {
        #expect(levenshteinDistance("cat", "cut") == 1)
    }

    @Test("Substitution at end gives distance 1")
    func substitutionAtEnd() {
        #expect(levenshteinDistance("bar", "bat") == 1)
    }

    // MARK: - Case Insensitivity

    @Test("Case insensitive: same word different case gives distance 0")
    func caseInsensitiveSameWord() {
        #expect(levenshteinDistance("Hello", "hello") == 0)
    }

    @Test("Case insensitive: mixed case gives distance 0")
    func caseInsensitiveMixedCase() {
        #expect(levenshteinDistance("HeLLo", "hEllO") == 0)
    }

    @Test("Case insensitive: all uppercase vs lowercase gives distance 0")
    func caseInsensitiveAllCaps() {
        #expect(levenshteinDistance("SWIFT", "swift") == 0)
    }

    @Test("Case insensitive: model names with different case give distance 0")
    func caseInsensitiveModelNames() {
        #expect(levenshteinDistance("Qwen2.5", "qwen2.5") == 0)
    }

    // MARK: - Known Examples

    @Test("kitten vs sitting has distance 3")
    func kittenSitting() {
        // kitten -> sitten (substitution s for k)
        // sitten -> sittin (substitution i for e)
        // sittin -> sitting (insertion g)
        #expect(levenshteinDistance("kitten", "sitting") == 3)
    }

    @Test("saturday vs sunday has distance 3")
    func saturdaySunday() {
        #expect(levenshteinDistance("saturday", "sunday") == 3)
    }

    @Test("flaw vs lawn has distance 2")
    func flawLawn() {
        #expect(levenshteinDistance("flaw", "lawn") == 2)
    }

    @Test("completely different strings")
    func completelyDifferent() {
        #expect(levenshteinDistance("abc", "xyz") == 3)
    }

    // MARK: - Model Name Scenarios

    @Test("Model name with small typo")
    func modelNameTypo() {
        let distance = levenshteinDistance("Qwen2.5-7B-Instruct-4bit", "Qwen2.5-7B-Instruc-4bit")
        #expect(distance == 1)
    }

    @Test("Model name with quantization variant")
    func modelNameQuantization() {
        let distance = levenshteinDistance("Qwen2.5-7B-Instruct-4bit", "Qwen2.5-7B-Instruct-8bit")
        #expect(distance == 1)
    }

    @Test("Single character strings")
    func singleCharacterStrings() {
        #expect(levenshteinDistance("a", "a") == 0)
        #expect(levenshteinDistance("a", "b") == 1)
        #expect(levenshteinDistance("a", "") == 1)
    }
}
