//
//  PingPongBarTests.swift
//  PingPongBarTests
//
//

import Testing
@testable import PingPongBar

struct HostValidatorTests {

    @Test func testHostBasicValidation() {
        // Valid hosts
        #expect(HostValidator.isValid("apple.com"))
        #expect(HostValidator.isValid("1.1.1.1"))
        #expect(HostValidator.isValid("google-public-dns-a.google.com"))
        #expect(HostValidator.isValid("localhost"))
        #expect(HostValidator.isValid("::1"))
        #expect(HostValidator.isValid("[2001:db8::1]"))

        // Security: Flag injection
        #expect(!HostValidator.isValid("-v"))
        #expect(!HostValidator.isValid("--version"))
        #expect(HostValidator.isValid(" apple.com")) // Trimming makes this valid
        
        // Security: ASCII restriction (Prevent non-ASCII unicode)
        #expect(!HostValidator.isValid("аррӏе.com")) // Cyrillic look-alike
        #expect(!HostValidator.isValid("domain.test;rm -rf /")) // Shell metacharacters
    }

    @Test func testIPAddressValidation() {
        // IPv4
        #expect(HostValidator.isValidIPAddress("8.8.8.8"))
        #expect(HostValidator.isValidIPAddress("127.0.0.1"))
        #expect(!HostValidator.isValidIPAddress("256.256.256.256"))

        // IPv6
        #expect(HostValidator.isValidIPAddress("2001:4860:4860::8888"))
        #expect(HostValidator.isValidIPAddress("::1"))
        #expect(!HostValidator.isValidIPAddress("2001:db8::z"))

        // Hostnames should be rejected by this specific method
        #expect(!HostValidator.isValidIPAddress("apple.com"))
    }

    @Test func testDomainValidation() {
        #expect(HostValidator.isValidDomain("apple.com"))
        #expect(HostValidator.isValidDomain("my-server.internal.net"))
        
        // Invalid domains
        #expect(!HostValidator.isValidDomain("apple")) // No dot
        #expect(!HostValidator.isValidDomain(".apple.com")) // Leading dot
        #expect(!HostValidator.isValidDomain("apple.com.")) // Trailing dot
        #expect(!HostValidator.isValidDomain("-apple.com")) // Leading hyphen in label
        #expect(!HostValidator.isValidDomain("apple-.com")) // Trailing hyphen in label
        
        // ASCII LDH rule (Letter, Digit, Hyphen)
        #expect(!HostValidator.isValidDomain("domаin.com")) // Cyrillic 'а'
    }
}
