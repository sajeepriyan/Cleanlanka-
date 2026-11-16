import {createHandler} from './handler.mjs';
export default {
 async fetch(request, env) {
  return createHandler({get: name => env[name]}, {
   fetch,
   allow: async userId => (await env.CALL_RATE_LIMITER.limit({key:userId})).success,
  })(request);
 }
};
