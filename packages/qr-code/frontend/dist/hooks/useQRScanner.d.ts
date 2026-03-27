import { type CameraConfig } from "@caffeineai/camera";
declare global {
    interface Window {
        jsQR: any;
    }
}
export interface QRResult {
    data: string;
    timestamp: number;
}
export interface QRScannerConfig extends CameraConfig {
    scanInterval?: number;
    maxResults?: number;
    jsQRUrl?: string;
}
export declare const useQRScanner: (config: QRScannerConfig) => {
    qrResults: QRResult[];
    isScanning: boolean;
    jsQRLoaded: boolean;
    isActive: boolean;
    isSupported: boolean | null;
    error: import("@caffeineai/camera").CameraError | null;
    isLoading: boolean;
    currentFacingMode: "user" | "environment";
    startScanning: () => Promise<boolean>;
    stopScanning: () => Promise<void>;
    switchCamera: () => Promise<boolean>;
    clearResults: () => void;
    reset: () => void;
    retry: () => Promise<boolean>;
    videoRef: import("react").RefObject<HTMLVideoElement | null>;
    canvasRef: import("react").RefObject<HTMLCanvasElement | null>;
    isReady: boolean;
    canStartScanning: boolean;
};
