/* ==========================================
   BridgeTouch - Interactive JavaScript
   ========================================== */

document.addEventListener('DOMContentLoaded', () => {
    initLatestVersionFetcher();
    initTrackpadSimulator();
});

/**
 * Fetch the latest release tag from GitHub and update the download button.
 */
async function initLatestVersionFetcher() {
    const versionEl = document.getElementById('latest-version');
    const heroBtn = document.getElementById('download-cta');
    const navBtn = document.getElementById('nav-download-btn');
    const githubUser = 'mouse0452';
    const repoName = 'BridgeTouch';
    
    try {
        const response = await fetch(`https://api.github.com/repos/${githubUser}/${repoName}/releases/latest`);
        if (!response.ok) throw new Error('Network response was not ok');
        
        const data = await response.json();
        if (data && data.tag_name) {
            versionEl.textContent = data.tag_name;
        }
        
        // Find .dmg asset in the release and set direct download URLs
        if (data && data.assets && data.assets.length > 0) {
            const dmgAsset = data.assets.find(asset => asset.name.endsWith('.dmg'));
            if (dmgAsset && dmgAsset.browser_download_url) {
                const directUrl = dmgAsset.browser_download_url;
                if (heroBtn) heroBtn.href = directUrl;
                if (navBtn) navBtn.href = directUrl;
            }
        }
    } catch (error) {
        console.warn('Failed to fetch latest release version from GitHub:', error);
        // Fallback values are set in HTML (pointing to the releases index page)
    }
}

/**
 * Interactive trackpad simulator.
 * Moving mouse/touch inside phone simulator moves the cursor on Mac simulator.
 */
function initTrackpadSimulator() {
    const trackpad = document.getElementById('sim-trackpad');
    const touchPoint = document.getElementById('sim-touch-point');
    const instruction = document.getElementById('trackpad-instruction');
    const cursor = document.getElementById('sim-cursor');
    const macScreen = document.getElementById('sim-mac-screen');
    
    if (!trackpad || !touchPoint || !cursor || !macScreen) return;
    
    let isTracking = false;
    let hasInteracted = false;
    
    // Hide instruction on first interaction
    const hideInstruction = () => {
        if (!hasInteracted) {
            instruction.style.opacity = '0';
            setTimeout(() => instruction.style.display = 'none', 500);
            hasInteracted = true;
        }
    };
    
    // Position updater
    const updatePosition = (clientX, clientY) => {
        const rect = trackpad.getBoundingClientRect();
        
        // Relative mouse coordinates within the trackpad
        let x = clientX - rect.left;
        let y = clientY - rect.top;
        
        // Clamp inside trackpad bounds
        x = Math.max(0, Math.min(x, rect.width));
        y = Math.max(0, Math.min(y, rect.height));
        
        // Update touch point dot on simulated iPhone screen
        touchPoint.style.left = `${x}px`;
        touchPoint.style.top = `${y}px`;
        touchPoint.style.opacity = '1';
        
        // Normalize coordinates (0.0 to 1.0)
        const normX = x / rect.width;
        const normY = y / rect.height;
        
        // Map to Mac Screen coordinates (width: 296px, height: 176px excluding outer borders)
        // Menu bar is 14px high.
        const macCursorX = normX * (296 - 18); // subtract cursor width to keep it on screen
        const macCursorY = 14 + (normY * (176 - 14 - 18)); // offset for menu bar & cursor height
        
        cursor.style.left = `${macCursorX}px`;
        cursor.style.top = `${macCursorY}px`;
    };
    
    // --- Mouse Events ---
    trackpad.addEventListener('mousedown', (e) => {
        isTracking = true;
        hideInstruction();
        updatePosition(e.clientX, e.clientY);
    });
    
    window.addEventListener('mousemove', (e) => {
        if (!isTracking) return;
        updatePosition(e.clientX, e.clientY);
    });
    
    window.addEventListener('mouseup', () => {
        if (isTracking) {
            isTracking = false;
            touchPoint.style.opacity = '0';
        }
    });
    
    trackpad.addEventListener('mouseleave', () => {
        touchPoint.style.opacity = '0';
    });
    
    // --- Touch Events (for mobile visitors) ---
    trackpad.addEventListener('touchstart', (e) => {
        if (e.touches.length === 0) return;
        isTracking = true;
        hideInstruction();
        const touch = e.touches[0];
        updatePosition(touch.clientX, touch.clientY);
        e.preventDefault(); // Prevent scrolling while using simulated trackpad
    }, { passive: false });
    
    trackpad.addEventListener('touchmove', (e) => {
        if (!isTracking || e.touches.length === 0) return;
        const touch = e.touches[0];
        updatePosition(touch.clientX, touch.clientY);
        e.preventDefault();
    }, { passive: false });
    
    trackpad.addEventListener('touchend', () => {
        isTracking = false;
        touchPoint.style.opacity = '0';
    });
}
