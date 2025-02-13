//
//  PRTextStorage.m
//  Proton
//
//  Created by Rajdeep Kwatra on 13/9/20.
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

#import "PRTextStorage.h"
#import "PREditorContentName.h"

@interface PRTextStorage ()
@property (nonatomic) NSTextStorage *storage;
@end

@interface NSString (ProtonExtension)
- (NSArray<NSValue *> *)rangesOfCharacterSet:(NSCharacterSet*)characterSet;
@end

@implementation PRTextStorage

- (instancetype)init {
    if (self = [super init]) {
        _storage = [[NSTextStorage alloc] init];
    }
    return self;
}

- (NSString *)string {
    return _storage.string;
}

- (UIFont *)defaultFont {
    return [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
}

- (NSParagraphStyle *)defaultParagraphStyle {
    return [[NSParagraphStyle alloc] init];
}

- (UIColor *)defaultTextColor {
    if (@available(iOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

- (id)attribute:(NSAttributedStringKey)attrName atIndex:(NSUInteger)location effectiveRange:(NSRangePointer)range {
    if (_storage.length <= location ) {
        return nil;
    }
    return [_storage attribute:attrName atIndex:location effectiveRange:range];
}

- (NSDictionary<NSString *, id> *)attributesAtIndex:(NSUInteger)location effectiveRange:(NSRangePointer)effectiveRange {
    if (_storage.length <= location ) {
        return nil;
    }
    return [_storage attributesAtIndex:location effectiveRange:effectiveRange];
}

- (void)edited:(NSTextStorageEditActions)editedMask range:(NSRange)editedRange changeInLength:(NSInteger)delta {
    [super edited:editedMask range:editedRange changeInLength:delta];
    [self.textStorageDelegate textStorage:self edited:editedMask in:editedRange changeInLength:delta];
}

- (NSAttributedString *)attributedSubstringFromRange:(NSRange)range {
    NSRange rangeToUse =[self clampedWithUpperBound:self.length location:range.location length:range.length];
    return [super attributedSubstringFromRange: rangeToUse];
}

- (NSRange)clampedWithUpperBound:(NSInteger)upperBound location:(NSInteger)location length:(NSInteger)length {
    NSInteger clampedLocation = MAX(MIN(location, upperBound), 0);
    NSInteger clampedLength = MAX(MIN(length, upperBound - clampedLocation), 0);
    return NSMakeRange(clampedLocation, clampedLength);
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)attrString {
    // Handles the crash when nested list receives enter key in quick succession that unindents the list item.
    // Check only required with Obj-C based TextStorage
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    NSMutableAttributedString *replacementString = [attrString mutableCopy];
    NSAttributedString *substring = [self attributedSubstringFromRange:range];

    if (self.preserveNewlineBeforeBlock
        && range.location > 0
        && [self attributedStringHasNewline:substring atStart:NO]
        && [self isCharacterAdjacentToRangeAnAttachment:self range:range checkBefore:NO]) {
        replacementString = [self appendNewlineToAttributedString:[attrString mutableCopy] atStart:NO];
    }

    if (self.preserveNewlineAfterBlock
        && range.location > 0
        && [self attributedStringHasNewline:substring atStart:YES]
        && [self isCharacterAdjacentToRangeAnAttachment:self range:range checkBefore:YES]) {
        replacementString = [self appendNewlineToAttributedString:[attrString mutableCopy] atStart:YES];
    }

    // Fix any missing attribute that is in the location being replaced, but not in the text that
    // is coming in.
    if (range.length > 0 && replacementString.length > 0) {
        NSDictionary<NSAttributedStringKey, id> *outgoingAttrs = [_storage attributesAtIndex:(range.location + range.length - 1) effectiveRange:nil];
        NSDictionary<NSAttributedStringKey, id> *incomingAttrs = [replacementString attributesAtIndex:0 effectiveRange:nil];

        // A list of keys we do not want to preserve when missing in the text that is coming in.
        NSArray *nonCarryoverKeys = @[
            [[PREditorContentName blockContentTypeName] rawValue],
            [[PREditorContentName inlineContentTypeName] rawValue],
            [[PREditorContentName isBlockAttachmentName] rawValue],
            [[PREditorContentName isInlineAttachmentName] rawValue],

            // We do not want to fix the underline since it can be added by the input method for
            // characters accepting diacritical marks (eg. in Vietnamese or Spanish) and should be transient.
            NSUnderlineStyleAttributeName
        ];

        NSMutableDictionary<NSAttributedStringKey, id> *filteredOutgoingAttrs = [outgoingAttrs mutableCopy];
        [filteredOutgoingAttrs removeObjectsForKeys:nonCarryoverKeys];

        NSMutableDictionary<NSAttributedStringKey, id> *diff = [NSMutableDictionary dictionary];
        for (NSAttributedStringKey outgoingKey in filteredOutgoingAttrs) {
            if (incomingAttrs[outgoingKey] == nil) {
                diff[outgoingKey] = filteredOutgoingAttrs[outgoingKey];
            }
        }
        [replacementString addAttributes:diff range:NSMakeRange(0, replacementString.length)];
    }

    // To maintain a consistent state of attributes, adding newline attributes to
    // all newline characters in the replacement string.
    NSArray<NSValue*> *newlineRangeValues =
    [replacementString.string rangesOfCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@"\n"]];
    for (NSValue *newlineRangeValue in newlineRangeValues) {
        [replacementString addAttribute:[[PREditorContentName blockContentTypeName] rawValue]
                                  value:[PREditorContentName newlineName]
                                  range:[newlineRangeValue rangeValue]];
    }

    NSAttributedString *deletedText = [_storage attributedSubstringFromRange:range];
    [_textStorageDelegate textStorage:self will:deletedText insertText:replacementString in:range];


    [self deleteAttachmentsInRange: range];
    [super replaceCharactersInRange:range withAttributedString: replacementString];
}

- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)str {
    [self deleteAttachmentsInRange: range];
    [self beginEditing];

    NSInteger delta = str.length - range.length;
    [_storage replaceCharactersInRange:range withString:str];
    [_storage fixAttributesInRange:NSMakeRange(0, _storage.length)];
    [self edited:NSTextStorageEditedCharacters | NSTextStorageEditedAttributes range:range changeInLength:delta];

    [self endEditing];
}

-(void)deleteAttachmentsInRange:(NSRange) range {
    // Capture any attachments in the original range to be deleted after editing is complete
    NSArray<NSTextAttachment *> *attachmentsToDelete = [self attachmentsForRange:range];
    // Deleting of Attachment needs to happen outside editing flow. If invoked while textStorage editing is
    // taking place, this may sometimes result in a crash(_fillLayoutHoleForCharacterRange).
    // If invoked after, it may still cause a crash as caret location is queried which may cause editor layout again
    // resulting in the crash.
    for (NSTextAttachment *attachment in attachmentsToDelete) {
        [_textStorageDelegate textStorage:self didDelete:attachment];
    }
}

- (void)setAttributes:(NSDictionary<NSString *, id> *)attrs range:(NSRange)range {
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    [self beginEditing];

    NSDictionary<NSAttributedStringKey, id> *updatedAttributes = [self applyingDefaultFormattingIfRequiredToAttributes:attrs];
    [_storage setAttributes:updatedAttributes range:range];

    [_storage fixAttributesInRange: range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
    [self endEditing];
}

- (void)insertAttachmentInRange:(NSRange)range attachment:(NSTextAttachment *_Nonnull)attachment withSpacer:(NSAttributedString *)spacer {
    NSCharacterSet *spacerCharacterSet = [NSCharacterSet whitespaceCharacterSet];  //attachment.spacerCharacterSet;
    BOOL hasNextSpacer = NO;
    if (range.location + 1 < self.length) {
        NSUInteger characterIndex = range.location + 1;
        hasNextSpacer = [spacerCharacterSet characterIsMember:[self.string characterAtIndex:characterIndex]];
    }

    NSMutableAttributedString *attachmentString = [[NSMutableAttributedString attributedStringWithAttachment:attachment] mutableCopy];

    if (hasNextSpacer == NO) {
        [attachmentString appendAttributedString:spacer];
    }

    [self replaceCharactersInRange:range withAttributedString:attachmentString];
}

- (void)addAttributes:(NSDictionary<NSAttributedStringKey, id> *)attrs range:(NSRange)range {
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    [self beginEditing];
    [_storage addAttributes:attrs range:range];
    [_storage fixAttributesInRange:NSMakeRange(0, _storage.length)];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
    [self endEditing];
}

- (void)removeAttributes:(NSArray<NSAttributedStringKey> *_Nonnull)attrs range:(NSRange)range {
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    [self beginEditing];
    for (NSAttributedStringKey attr in attrs) {
        [_storage removeAttribute:attr range:range];
    }
    [self fixMissingAttributesForDeletedAttributes:attrs range:range];
    [_storage fixAttributesInRange:NSMakeRange(0, _storage.length)];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
    [self endEditing];
}

- (void)removeAttribute:(NSAttributedStringKey)name range:(NSRange)range {
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    [_storage removeAttribute:name range:range];
}

#pragma mark - Private

- (NSMutableAttributedString *)appendNewlineToAttributedString:(NSMutableAttributedString *)attributedString atStart:(BOOL)appendAtStart {
    if (attributedString.length == 0) {
        return [[NSMutableAttributedString alloc] initWithString:@"\n"]; // Return just a newline if the original string is empty.
    }

    // Create a new NSAttributedString with the newline character.
    NSAttributedString *newlineAttributedString = [[NSAttributedString alloc] initWithString:@"\n"];

    // Create a mutable copy of the original attributed string.
    NSMutableAttributedString *mutableAttributedString = [[NSMutableAttributedString alloc] initWithAttributedString:attributedString];

    if (appendAtStart) {
        // Append the attributed newline at the start.
        [mutableAttributedString insertAttributedString:newlineAttributedString atIndex:0];
    } else {
        // Append the attributed newline at the end.
        [mutableAttributedString appendAttributedString:newlineAttributedString];
    }

    return mutableAttributedString;
}

- (BOOL) attributedStringHasNewline:(NSAttributedString *) attributedString atStart: (BOOL)atStart {
    NSString *string = [attributedString string];
    if (string.length == 0) {
        return NO;
    }

    unichar characterToVerify = [string characterAtIndex: 0];
    if (atStart == NO) {
        characterToVerify = [string characterAtIndex:string.length - 1];
    }

    return [[NSCharacterSet newlineCharacterSet] characterIsMember:characterToVerify];
}

-(BOOL) isCharacterAdjacentToRangeAnAttachment: (NSAttributedString *) attributedString range: (NSRange) range checkBefore: (BOOL) checkBefore {
    NSUInteger positionToCheck;

    if (checkBefore) {
        if (range.location == 0) {
            return NO; // No character before the start of the string
        }
        positionToCheck = range.location - 1;
    } else {
        positionToCheck = NSMaxRange(range);
        if (positionToCheck >= attributedString.length) {
            return NO; // No character after the end of the string
        }
    }

    // Retrieve the attributes at the position to check
    NSDictionary *attributes = [attributedString attributesAtIndex:positionToCheck effectiveRange:NULL];

    // Check if these attributes contain the NSAttachmentAttributeName
    if ([attributes objectForKey:@"_isBlockAttachment"] != nil) {
        return YES; // There is an attachment
    }

    return NO; // No attachment found
}

- (void)fixMissingAttributesForDeletedAttributes:(NSArray<NSAttributedStringKey> *)attrs range:(NSRange)range {
    if ((range.location + range.length) > _storage.length) {
        // Out of bounds
        return;
    }

    if ([attrs containsObject:NSForegroundColorAttributeName]) {
        [_storage addAttribute:NSForegroundColorAttributeName value:self.defaultTextColor range:range];
    }

    if ([attrs containsObject:NSParagraphStyleAttributeName]) {
        [_storage addAttribute:NSParagraphStyleAttributeName value:self.defaultParagraphStyle range:range];
    }

    if ([attrs containsObject:NSFontAttributeName]) {
        [_storage addAttribute:NSFontAttributeName value:self.defaultFont range:range];
    }
}

- (NSDictionary<NSAttributedStringKey, id> *)applyingDefaultFormattingIfRequiredToAttributes:(NSDictionary<NSAttributedStringKey, id> *)attributes {
    NSMutableDictionary<NSAttributedStringKey, id> *updatedAttributes = attributes.mutableCopy ?: [NSMutableDictionary dictionary];

    if (!attributes[NSParagraphStyleAttributeName]) {
        updatedAttributes[NSParagraphStyleAttributeName] = _defaultTextFormattingProvider.paragraphStyle.copy ?: self.defaultParagraphStyle;
    }

    if (!attributes[NSFontAttributeName]) {
        updatedAttributes[NSFontAttributeName] = _defaultTextFormattingProvider.font ?: self.defaultFont;
    }

    if (!attributes[NSForegroundColorAttributeName]) {
        updatedAttributes[NSForegroundColorAttributeName] = _defaultTextFormattingProvider.textColor ?: self.defaultTextColor;
    }

    return updatedAttributes;
}

- (NSArray<NSTextAttachment *> *)attachmentsForRange:(NSRange)range {
    NSMutableArray<NSTextAttachment *> *attachments = [NSMutableArray array];
    [_storage enumerateAttribute:NSAttachmentAttributeName
                         inRange:range
                         options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired
                      usingBlock:^(id _Nullable value, NSRange range, BOOL *_Nonnull stop) {
        if ([value isKindOfClass:[NSTextAttachment class]]) {
            [attachments addObject:value];
        }
    }];
    return attachments;
}

@end

@implementation NSString (ProtonExtension)

- (NSArray<NSValue *> *)rangesOfCharacterSet:(NSCharacterSet*)characterSet {
    NSMutableArray *ranges = [NSMutableArray array];
    NSRange searchRange = NSMakeRange(0, self.length);

    NSRange range = [self rangeOfCharacterFromSet:characterSet options:0 range:searchRange];

    while (range.location != NSNotFound) {
        [ranges addObject:[NSValue valueWithRange:range]];

        NSUInteger newStart = NSMaxRange(range);
        searchRange = NSMakeRange(newStart, self.length - newStart);
        range = [self rangeOfCharacterFromSet:characterSet options:0 range:searchRange];
    }

    return [ranges copy];
}

@end
