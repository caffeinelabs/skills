export interface CameraConfig {
    facingMode?: "user" | "environment";
    width?: number;
    height?: number;
    quality?: number;
    format?: "image/jpeg" | "image/png" | "image/webp";
}
export interface CameraError {
    type: "permission" | "not-supported" | "not-found" | "unknown";
    message: string;
}
export declare const useCamera: (config?: CameraConfig) => {
    isActive: boolean;
    isSupported: boolean | null;
    error: CameraError | null;
    isLoading: boolean;
    currentFacingMode: "user" | "environment";
    startCamera: () => Promise<boolean>;
    stopCamera: () => Promise<void>;
    capturePhoto: () => Promise<File | null>;
    switchCamera: (newFacingMode?: "user" | "environment") => Promise<boolean>;
    retry: () => Promise<boolean>;
    videoRef: import("react").RefObject<HTMLVideoElement | null>;
    canvasRef: import("react").RefObject<HTMLCanvasElement | null>;
};
