import {createHandler} from './handler.mjs';
export default {
 async fetch(request, env) {
  return createHandler({get: name => env[name]}, {
   fetch: (url, options) => fetch(url, options),
   allow: async userId => (await env.CALL_RATE_LIMITER.limit({key:userId})).success,
  })(request);
 }
};
