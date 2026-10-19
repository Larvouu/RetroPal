Module.noInitialRun = true;
Module.preRun = [() => {
	FS.mount(IDBFS, {autoPersist: true}, '/home/web_user');
	FS.syncfs(true, (err) => {
		if (err) {
			console.log('Error loading IDBFS', err);
		}
		Module.callMain();
	});
}];
