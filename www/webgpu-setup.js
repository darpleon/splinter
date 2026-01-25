var Module = {
    print: (function() {
        return (text) => { console.log(text); };
    })(),
    canvas: (function() {
        return document.getElementById('canvas');
    })(),
};

async function initWebGPU() {
    if (!('gpu' in navigator)) {
        console.error('WebGPU not available.\n You might need to set some flags');
        return false;
    }

    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) {
        console.error('No WebGPU adapters found.');
        return false;
    }

    const device = await adapter.requestDevice();
    
    Module.preinitializedWebGPUDevice = device;

    return true;
}

initWebGPU();
