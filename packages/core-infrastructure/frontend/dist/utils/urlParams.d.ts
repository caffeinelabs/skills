/**
 * Utility functions for parsing and managing URL parameters
 * Works with both hash-based and browser-based routing
 */
/**
 * Extracts a URL parameter from the current URL
 * Works with both query strings (?param=value) and hash-based routing (#/?param=value)
 *
 * @param paramName - The name of the parameter to extract
 * @returns The parameter value if found, null otherwise
 */
export declare function getUrlParameter(paramName: string): string | null;
/**
 * Stores a parameter in sessionStorage for persistence across navigation
 * Useful for maintaining state like admin tokens throughout the session
 *
 * @param key - The key to store the value under
 * @param value - The value to store
 */
export declare function storeSessionParameter(key: string, value: string): void;
/**
 * Retrieves a parameter from sessionStorage
 *
 * @param key - The key to retrieve
 * @returns The stored value if found, null otherwise
 */
export declare function getSessionParameter(key: string): string | null;
/**
 * Gets a parameter from URL or sessionStorage (URL takes precedence)
 * If found in URL, also stores it in sessionStorage for future use
 *
 * @param paramName - The name of the parameter to retrieve
 * @param storageKey - Optional custom storage key (defaults to paramName)
 * @returns The parameter value if found, null otherwise
 */
export declare function getPersistedUrlParameter(paramName: string, storageKey?: string): string | null;
/**
 * Removes a parameter from sessionStorage
 *
 * @param key - The key to remove
 */
export declare function clearSessionParameter(key: string): void;
/**
 * Gets a secret from the URL hash fragment only (more secure than query params)
 * Hash fragments aren't sent to servers or logged in access logs
 * The hash is immediately cleared from the URL after extraction to prevent history leakage
 *
 * Usage: https://yourapp.com/#secret=xxx
 *
 * @param paramName - The name of the secret parameter
 * @returns The secret value if found (from hash or session), null otherwise
 */
export declare function getSecretFromHash(paramName: string): string | null;
/**
 * Gets a secret parameter with fallback chain: hash -> sessionStorage
 * This is the recommended way to handle sensitive parameters like admin tokens
 *
 * Security benefits over regular URL params:
 * - Hash fragments are not sent to the server
 * - Not logged in server access logs
 * - Not sent in HTTP Referer headers
 * - Automatically cleared from URL after extraction
 *
 * @param paramName - The name of the secret parameter
 * @returns The secret value if found, null otherwise
 */
export declare function getSecretParameter(paramName: string): string | null;
