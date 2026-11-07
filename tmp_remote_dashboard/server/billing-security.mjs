import { randomBytes,scrypt,timingSafeEqual,createHash } from 'node:crypto';
import { promisify } from 'node:util';
const derive=promisify(scrypt);
export const isUuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
export const projectStates=new Set(['planned','in_progress','waiting_customer','on_hold','completed','cancelled']);
export function validateProject(b,{edit=false}={}){
 if(!b||typeof b.title!=='string'||!b.title.trim()||b.title.trim().length>120||typeof b.description!=='string'||b.description.length>12000||typeof b.internalNote!=='string'||b.internalNote.length>12000||!projectStates.has(b.status))throw new Error('Invalid project title, notes or status.');
 if(edit&&(!Number.isInteger(b.revision)||b.revision<1))throw new Error('Refresh the project before editing.');
 return {title:b.title.trim(),description:b.description,internalNote:b.internalNote,status:b.status,...(edit?{revision:b.revision}:{})};
}
export async function hashPin(pin){if(typeof pin!=='string'||!/^\d{6,12}$/.test(pin))throw new Error('Use a 6–12 digit account PIN.');const salt=randomBytes(16).toString('hex');const hash=await derive(pin,salt,32);return {salt,hash:hash.toString('hex')};}
export async function verifyPin(pin,salt,expected){if(typeof pin!=='string'||!/^\d{6,12}$/.test(pin)||typeof salt!=='string'||typeof expected!=='string'||!/^[a-f0-9]{64}$/.test(expected))return false;const actual=await derive(pin,salt,32);return timingSafeEqual(actual,Buffer.from(expected,'hex'));}
export const tokenHash=token=>createHash('sha256').update(token).digest('hex');
export const newBillingSession=()=>randomBytes(32).toString('base64url');
export function publicProject(p){return {id:p.id,title:p.title,description:p.description,status:p.status,revision:p.revision,updatedAt:p.updated_at,createdAt:p.created_at,closed:p.status==='completed'||p.status==='cancelled'};}
export function safeAccount(row){return {id:row.id,householdId:row.household_id,householdName:row.household_name,merchantId:row.merchant_id,customerId:row.customer_id,customerName:row.customer_name,environment:row.environment,accessMode:row.access_mode,active:row.active,createdAt:row.created_at};}
