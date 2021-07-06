/**
 TODO: Revisit thread handling with promises regarding these tests
 */
xdescribe("Promise scheduling", function () {
    it("should be executed", function(done) {
        Promise.resolve().then(done);
    });

    it("the 'then' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).then(res => {
            expect(res).toBe(expectedResult);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).catch(e => {
            expect(true).toBe(false, "The catch callback of the promise was called");
            done();
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'then' callback (with onRejected handler) should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).then(res => {
            expect(res).toBe(expectedResult);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }, e => {
            expect(true).toBe(false, "The catch callback of the promise was called");
            done();
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'catch' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedError = new Error("oops");

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => reject(expectedError));
        }).then(res => {
            expect(true).toBe(false, "The then callback of the promise was called");
            done();
        }).catch(e => {
            expect(e).toBe(expectedError);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'catch' callback (with onRejected handler) should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedError = new Error("oops");

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => reject(expectedError));
        }).then(res => {
            expect(true).toBe(false, "The then callback of the promise was called");
            done();
        }, e => {
            expect(e).toBe(expectedError);
            expect(NSThread.currentThread.hash).toBe(expectedHash);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("the 'finally' callback should be executed on the same thread on which the Promise was created", done => {
        const expectedHash = NSThread.currentThread.hash;
        const expectedResult = {
            message: "ok"
        };

        new Promise((resolve, reject) => {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(expectedResult));
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            done();
        });
    });

    it("chaining promises with return values", done => {
        const expectedHash = NSThread.currentThread.hash;
        let expectedValues = [1, 2, 4, 8];
        let actualValues = [];

        new Promise(function(resolve, reject) {
            let queue = NSOperationQueue.alloc().init();
            queue.addOperationWithBlock(() => resolve(1));
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return value * 2;
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return new Promise((res, rej) => setTimeout(() => res(value * 2), 50));
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
            return Promise.resolve(value * 2);
        }).then(value => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            actualValues.push(value);
        }).finally(() => {
            expect(NSThread.currentThread.hash).toBe(expectedHash);
            expect(actualValues).toEqual(expectedValues);
            done();
        });
    });
});
